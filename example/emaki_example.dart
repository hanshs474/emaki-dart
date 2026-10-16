import 'dart:io';

import 'package:emaki/emaki.dart';

Future<void> main() async {
  final emaki = Emaki(); // reads EMAKI_API_KEY
  try {
    print(await emaki.generateVideo(
        'a paper lantern drifting over a night river, slow dolly',
        params: {'duration': 5, 'resolution': '480p'}));
  } on EmakiException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    emaki.close();
  }
}
