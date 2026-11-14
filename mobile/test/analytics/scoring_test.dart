import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/scoring.dart';
import 'package:r6_coach/analytics/stats.dart';

void main() {
  test('small-sample win rate is shrunk', () {
    expect(bayesRate(1, 1), closeTo(2 / 3, 1e-9));
    expect(bayesRate(5, 10), closeTo(0.5, 1e-9));
  });

  test('wilson interval widens for small samples', () {
    final a = wilsonInterval(8, 10);
    final b = wilsonInterval(80, 100);
    expect(a.$2 - a.$1, greaterThan(b.$2 - b.$1));
    expect(a.$1, inInclusiveRange(0, 1));
  });

  test('consistency prefers the steady player and needs enough data', () {
    final steady = consistencyIndex([74, 76, 75, 75, 74, 76])!;
    final erratic = consistencyIndex([95, 40, 92, 38, 94, 41])!;
    expect(steady, greaterThan(erratic));
    expect(consistencyIndex([80, 70]), isNull);
  });

  test('missing data is null, not zero', () {
    final r = scoreMatch(const MatchStats());
    expect(r.score, isNull);
    expect(r.provisional, isTrue);
    expect(r.confidence, 'low');
  });

  test('partial data is provisional and renormalized', () {
    final r = scoreMatch(const MatchStats(roundsPlayed: 10, roundsWon: 6, kills: 9, deaths: 7, headshots: 4));
    expect(r.components['tactical'], isNull);
    expect(r.provisional, isTrue);
    expect(r.score, inInclusiveRange(0, 100));
    expect(r.version, '0.1.0');
  });

  test('high kills while losing vs low kills while winning', () {
    final frag = scoreMatch(const MatchStats(roundsPlayed: 14, roundsWon: 5, kills: 18, deaths: 9, headshots: 8));
    final support = scoreMatch(const MatchStats(roundsPlayed: 14, roundsWon: 9, kills: 7, deaths: 8, headshots: 3));
    expect(frag.components['mechanical']!, greaterThan(support.components['mechanical']!));
    expect(support.components['objective']!, greaterThan(frag.components['objective']!));
  });

  test('unknown mode falls back with a note', () {
    final r = scoreMatch(const MatchStats(mode: 'mystery', roundsPlayed: 8, roundsWon: 4));
    expect(r.notes.any((n) => n.contains('No config')), isTrue);
  });
}
