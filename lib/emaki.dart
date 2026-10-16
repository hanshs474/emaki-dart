/// Official SDK for emaki (https://emaki.ai), the Japanese-language AI video
/// generator for Seedance 2.5 and Seedance 2.0.
///
/// ```dart
/// final emaki = Emaki(); // reads EMAKI_API_KEY
/// final clip = await emaki.generateVideo('a paper lantern drifting over a night river');
/// ```
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:http/http.dart' as http;

/// The service this package talks to.
const baseUrl = 'https://emaki.ai';

/// Where an API key is created.
const keysUrl = 'https://emaki.ai/settings/apikeys';

/// Default video model: Seedance 2.5.
const modelVideo = 'seedance_2_5';

/// Default image model: the cheapest one.
const modelImage = 'nano_banana_2_lite';

/// What went wrong, split by what to do next.
enum EmakiErrorKind {
  /// No API key, or the key is invalid or deleted (HTTP 401).
  auth,

  /// The account is out of credits (HTTP 402).
  quota,

  /// The model unlocks after a credit purchase (HTTP 403).
  plan,

  /// A generation on this account is already in progress (HTTP 409).
  busy,

  /// The content filter refused the prompt or image; reword it.
  rejected,

  /// A parameter the API did not accept (HTTP 400).
  validation,

  /// The run ended as failed; see [EmakiException.failureCode].
  failed,

  /// The deadline passed; the run may still finish in your emaki library.
  timeout,

  /// Transport failure or an unexpected answer.
  other,
}

/// Every error this package throws.
class EmakiException implements Exception {
  final EmakiErrorKind kind;
  final String message;
  final int? statusCode;
  final String? failureCode;

  const EmakiException(this.kind, this.message,
      {this.statusCode, this.failureCode});

  @override
  String toString() => 'EmakiException(${kind.name}): $message';
}

/// Map an HTTP status and error body to the exception that says what to do next.
EmakiException classify(int status, Object? body) {
  final m = body is Map ? body : const {};
  final msg = (m['error'] ?? m['message'] ?? 'request failed').toString();
  final tag = m['code'] is String ? m['code'] as String : '';
  final low = msg.toLowerCase();
  EmakiErrorKind kind;
  if (status == 401) {
    kind = EmakiErrorKind.auth;
  } else if (status == 402) {
    kind = EmakiErrorKind.quota;
  } else if (status == 403) {
    kind = EmakiErrorKind.plan;
  } else if (status == 409) {
    kind = EmakiErrorKind.busy;
  } else if (tag == 'content_cooldown' || tag == 'content_blocked') {
    kind = EmakiErrorKind.rejected;
  } else if (status == 400) {
    kind = EmakiErrorKind.validation;
  } else if (status == 200 &&
      (low.contains('api key') || low.contains('unauthorized'))) {
    // The credits endpoint answers HTTP 200 with code -1.
    kind = EmakiErrorKind.auth;
  } else {
    kind = EmakiErrorKind.other;
  }
  return EmakiException(kind, msg, statusCode: status);
}

/// One run as `/api/video/status` reports it.
class EmakiStatus {
  final String id;

  /// 'generating', 'completed' or 'failed'.
  final String status;

  /// The finished file (video or image) once [status] is 'completed'.
  final String? url;
  final String? failureCode;

  /// The whole `data` object as the API sent it.
  final Map<String, dynamic> raw;

  EmakiStatus(this.raw)
      : id = '${raw['id'] ?? ''}',
        status = '${raw['status'] ?? ''}',
        url = raw['videoUrl'] as String?,
        failureCode = raw['failureCode'] as String?;
}

/// A client bound to one API key.
class Emaki {
  final String apiKey;
  final String base;
  final http.Client _client;

  /// Time between status checks.
  Duration pollEvery;

  /// Total wait for one run; video can queue.
  Duration timeout;

  /// An empty or missing key reads EMAKI_API_KEY.
  Emaki(
      [String? apiKey,
      String? base,
      http.Client? client,
      this.pollEvery = const Duration(seconds: 5),
      this.timeout = const Duration(minutes: 15)])
      : apiKey = (apiKey == null || apiKey.isEmpty) ? _envKey() : apiKey,
        base = base ?? baseUrl,
        _client = client ?? http.Client();

  static String _envKey() {
    try {
      return (Platform.environment['EMAKI_API_KEY'] ?? '').trim();
    } catch (_) {
      return ''; // web: no environment
    }
  }

  /// Start a run and return its id without waiting.
  Future<String> submit(String prompt,
      {String model = modelVideo,
      Map<String, Object?> params = const {}}) async {
    if (prompt.trim().isEmpty) {
      throw const EmakiException(
          EmakiErrorKind.validation, 'prompt is required');
    }
    final (code, body) = await _post('/api/video/ai',
        {'prompt': prompt, 'model': model, 'parameters': params});
    if (code == 200 && body is Map && body['success'] == true) {
      final id = (body['data'] as Map?)?['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    throw classify(code, body);
  }

  /// Look up a run.
  Future<EmakiStatus> status(String id) async {
    final (code, body) = await _post('/api/video/status', {'videoId': id});
    if (code == 200 &&
        body is Map &&
        body['success'] == true &&
        body['data'] is Map) {
      return EmakiStatus(Map<String, dynamic>.from(body['data'] as Map));
    }
    throw classify(code, body);
  }

  /// Credits left on the account. Free to call.
  Future<int> credits() async {
    final (code, body) = await _post('/api/user/get-user-credits', {});
    if (code == 200 &&
        body is Map &&
        body['code'] == 0 &&
        body['data'] is Map) {
      return ((body['data'] as Map)['remainingCredits'] as num).toInt();
    }
    throw classify(code, body);
  }

  /// Generate a clip (Seedance 2.5 by default) and return its URL.
  Future<String> generateVideo(String prompt,
          {String model = modelVideo,
          Map<String, Object?> params = const {}}) =>
      generate(prompt, model: model, params: params);

  /// Generate an image (the cheapest model by default) and return its URL.
  Future<String> generateImage(String prompt,
          {String model = modelImage,
          Map<String, Object?> params = const {}}) =>
      generate(prompt, model: model, params: params);

  /// Submit, wait, and return the URL of the finished file.
  Future<String> generate(String prompt,
      {required String model, Map<String, Object?> params = const {}}) async {
    final id = await submit(prompt, model: model, params: params);
    return wait(id);
  }

  /// Wait for a submitted run and return its URL.
  Future<String> wait(String id) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollEvery);
      EmakiStatus st;
      try {
        st = await status(id);
      } on EmakiException catch (e) {
        if (e.kind == EmakiErrorKind.auth) rethrow;
        continue; // a dropped poll is not a failed run
      } catch (_) {
        continue;
      }
      if ((st.status == 'completed' || st.status == 'succeeded') &&
          st.url != null) {
        return st.url!;
      }
      if (st.status == 'failed') {
        final code = st.failureCode ?? 'unknown';
        throw EmakiException(EmakiErrorKind.failed, 'generation failed ($code)',
            failureCode: code);
      }
    }
    throw const EmakiException(EmakiErrorKind.timeout,
        'deadline passed; the run may still finish in your library');
  }

  /// Close the underlying HTTP client.
  void close() => _client.close();

  Future<(int, Object?)> _post(String path, Object body) async {
    if (apiKey.isEmpty) {
      throw const EmakiException(EmakiErrorKind.auth,
          'set EMAKI_API_KEY or pass a key; create one at $keysUrl');
    }
    final http.Response res;
    try {
      res = await _client.post(Uri.parse('$base$path'),
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
            'User-Agent': 'emaki-dart/0.1.0',
          },
          body: jsonEncode(body));
    } catch (e) {
      throw EmakiException(EmakiErrorKind.other, e.toString());
    }
    Object? parsed;
    try {
      parsed = jsonDecode(res.body);
    } catch (_) {
      parsed = null;
    }
    return (res.statusCode, parsed);
  }
}
