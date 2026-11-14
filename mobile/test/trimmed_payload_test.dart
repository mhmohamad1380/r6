import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/data/replay.dart';

/// The Windows uploader reads each replay on the PC and sends only the fields the apps use. The phone must see exactly
/// what it saw when the server sent the full parser output. test/fixtures/replays/trimmed holds the trimmed twin of each
/// real fixture, made by the server's reference trim (backend/app/parsed.py trim_dissect).
void main() {
  final dir = Directory('test/fixtures/replays/trimmed');
  final names = [for (final f in dir.listSync().whereType<File>()) f.uri.pathSegments.last]..sort();

  test('there are real fixtures to compare', () => expect(names.length, greaterThanOrEqualTo(5)));

  for (final name in names) {
    test('$name: the phone reads the trimmed round exactly as it reads the full one', () {
      final full = parseReplayJson(File('test/fixtures/replays/$name').readAsStringSync());
      final small = parseReplayJson(File('${dir.path}/$name').readAsStringSync());
      expect(small.errors, 0);
      expect(small.rounds.length, full.rounds.length);
      expect(small.rounds, isNotEmpty);
      for (var i = 0; i < full.rounds.length; i++) {
        expect(jsonEncode(small.rounds[i].toJson()), jsonEncode(full.rounds[i].toJson()));
      }
    });
  }

  test('the trimmed twins are much smaller', () {
    for (final name in names) {
      final big = File('test/fixtures/replays/$name').lengthSync(), small = File('${dir.path}/$name').lengthSync();
      expect(small, lessThan(big), reason: name);
    }
  });
}
