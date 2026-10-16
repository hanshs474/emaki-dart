import 'dart:convert';
import 'dart:io';

import 'package:emaki/emaki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Replies in the real response shapes: submit, one "generating", then [final_].
Emaki fake(List<Map> calls, Map final_) {
  var polls = 0;
  return Emaki('sk', 'https://t', MockClient((r) async {
    calls.add(jsonDecode(r.body) as Map);
    switch (r.url.path) {
      case '/api/video/ai':
        return http.Response(
            jsonEncode({
              'success': true,
              'data': {'id': 'v1', 'status': 'generating'}
            }),
            200);
      case '/api/user/get-user-credits':
        return http.Response(
            jsonEncode({
              'code': 0,
              'message': 'ok',
              'data': {'remainingCredits': 7, 'hasPurchasedCredits': false}
            }),
            200);
    }
    polls++;
    final d = polls < 2
        ? {'id': 'v1', 'status': 'generating', 'videoUrl': null}
        : final_;
    return http.Response(jsonEncode({'success': true, 'data': d}), 200);
  }), Duration.zero);
}

void main() {
  test('video flow', () async {
    final calls = <Map>[];
    final c = fake(calls,
        {'id': 'v1', 'status': 'completed', 'videoUrl': 'https://cdn/x.mp4'});
    expect(await c.generateVideo('x', params: {'duration': 8}),
        'https://cdn/x.mp4');
    expect(calls[0], {
      'prompt': 'x',
      'model': 'seedance_2_5',
      'parameters': {'duration': 8}
    });
    expect(calls[1], {'videoId': 'v1'});
    expect(await c.credits(), 7);
  });

  test('failed run carries the code', () async {
    final c = fake(
        [], {'id': 'v1', 'status': 'failed', 'failureCode': 'content_policy'});
    await expectLater(
        c.generateImage('x'),
        throwsA(isA<EmakiException>()
            .having((e) => e.kind, 'kind', EmakiErrorKind.failed)
            .having((e) => e.failureCode, 'code', 'content_policy')));
  });

  test('classify', () {
    expect(
        classify(401, {
          'error':
              'Invalid API key. Create one at https://emaki.ai/settings/apikeys'
        }).kind,
        EmakiErrorKind.auth);
    expect(classify(402, {'error': 'Insufficient credits'}).kind,
        EmakiErrorKind.quota);
    expect(classify(403, {'error': 'buy credits first'}).kind,
        EmakiErrorKind.plan);
    expect(
        classify(409, {'error': 'Video generation is already in progress'})
            .kind,
        EmakiErrorKind.busy);
    expect(classify(429, {'error': 'wait', 'code': 'content_cooldown'}).kind,
        EmakiErrorKind.rejected);
    expect(classify(400, {'error': 'blocked', 'code': 'content_blocked'}).kind,
        EmakiErrorKind.rejected);
    expect(
        classify(
                400, {'error': 'Missing required parameters: prompt and model'})
            .kind,
        EmakiErrorKind.validation);
    expect(classify(500, {'error': 'Internal server error'}).kind,
        EmakiErrorKind.other);
    expect(
        classify(200, {
          'code': -1,
          'message':
              'Invalid API key. Create one at https://emaki.ai/settings/apikeys'
        }).kind,
        EmakiErrorKind.auth);
  });

  // Live: EMAKI_LIVE=1 EMAKI_API_KEY=... dart test
  test('live smoke', () async {
    expect(await Emaki().credits(), greaterThanOrEqualTo(0));
    await expectLater(
        Emaki('sk-wrong-key-for-test').submit('test', model: modelImage),
        throwsA(isA<EmakiException>()
            .having((e) => e.kind, 'kind', EmakiErrorKind.auth)));
  },
      skip: Platform.environment['EMAKI_LIVE'] == null
          ? 'set EMAKI_LIVE=1'
          : false);
}
