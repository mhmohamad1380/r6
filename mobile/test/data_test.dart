import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/insights.dart';
import 'package:r6_coach/analytics/scoring.dart';
import 'package:r6_coach/data/models.dart';

Map<String, dynamic> load(String n) => jsonDecode(File('test/fixtures/$n.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final profile = PlayerProfile.fromJson(load('profile'));
  final ops = OperatorStat.listFromResponse(load('operators'));

  test('profile parses identity, boards and RP history', () {
    expect(profile.name, 'cyruson1001');
    expect(profile.level, 64);
    expect(profile.ranked!.rankPoints, 2058);
    expect(profile.ranked!.matches, 20);
    expect(profile.ranked!.kd, closeTo(46 / 83, 1e-9));
    expect(profile.rankedSeason!.shortName, 'Y11S3');
    expect(profile.currentRankName, 'Silver 5');
    expect(profile.rpHistory.length, 16);
    expect(profile.rpHistory.first.at.isAfter(profile.rpHistory.last.at), isTrue);
  });

  test('operators parse with opening duel data', () {
    expect(ops.length, 27);
    final kapkan = ops.firstWhere((o) => o.name == 'Kapkan');
    expect(kapkan.side, 'Defender');
    expect(kapkan.firstBloods, 9);
    expect(kapkan.firstDeaths, 18);
    expect(kapkan.kd, closeTo(103 / 145, 1e-9));
  });

  test('missing fields stay null, not zero', () {
    final o = OperatorStat.fromJson({'operator': 'X', 'side': 'Attacker'});
    expect(o.kills, isNull);
    expect(o.kd, isNull);
    expect(scoreMatch(statsFor(o)).score, isNull);
    final p = PlayerProfile.fromJson({});
    expect(p.ranked, isNull);
    expect(p.rpHistory, isEmpty);
  });

  test('aggregate sums only reported fields', () {
    final a = aggregate([
      const OperatorStat(name: 'A', side: 'Attacker', kills: 3),
      const OperatorStat(name: 'B', side: 'Attacker', kills: 4, deaths: 2),
    ]);
    expect(a.kills, 7);
    expect(a.deaths, 2);
    expect(a.headshots, isNull);
  });

  test('real account gets a full, non-provisional score with a tactical part', () {
    final s = scoreMatch(aggregate(ops));
    expect(s.components['tactical'], isNotNull);
    expect(s.provisional, isFalse);
    expect(s.score, inInclusiveRange(0, 100));
  });

  test('insights state sample sizes and respect minimums', () {
    final items = buildInsights(ops);
    expect(items, isNotEmpty);
    expect(items.every((i) => i.sample > 0), isTrue);
    final tiny = buildInsights(const [OperatorStat(name: 'A', side: 'Attacker', roundsPlayed: 10, kills: 5, deaths: 5)]);
    expect(tiny.single.title, 'Not enough data yet');
  });
}
