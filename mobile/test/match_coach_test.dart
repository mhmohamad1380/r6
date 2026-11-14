import 'package:flutter_test/flutter_test.dart';
import 'package:r6_coach/analytics/match_coach.dart';
import 'package:r6_coach/analytics/replay_report.dart';

import 'support/synthetic_replays.dart';

void main() {
  final rich = asPlayer(richSet(), 'cyruson1001');

  test('every match with enough rounds is scored and reviewed, newest first', () {
    final c = buildMatchCoach(rich, 'cyruson1001');
    expect(c.reviews.length, 8);
    final dates = [for (final r in c.reviews) r.at!];
    for (var i = 1; i < dates.length; i++) {
      expect(dates[i - 1].isAfter(dates[i]) || dates[i - 1] == dates[i], isTrue);
    }
    expect(c.reviews.every((r) => r.score != null && r.rounds == 6), isTrue);
  });

  test('a good match after bad ones is a strong win, a bad one is a rough game, each with reasons', () {
    final c = buildMatchCoach(rich, 'cyruson1001');
    final newest = c.reviews.first, oldest = c.reviews.last;
    expect(newest.score!, greaterThan(oldest.score!));
    expect(newest.vsUsual!, greaterThan(8));
    expect(newest.headline, contains('above your usual'));
    expect(newest.won, isTrue);
    expect(newest.strengths, isNotEmpty);
    expect(newest.strengths.first.text, contains('usually'), reason: 'the number is shown next to your usual one');
    expect(oldest.vsUsual!, lessThan(-8));
    expect(oldest.headline, contains('below your usual'));
    expect(oldest.won, isFalse);
    expect(oldest.weaknesses, isNotEmpty);
    expect(oldest.weaknesses.every((r) => r.diff <= -12), isTrue);
  });

  test('best and worst match are named', () {
    final v = buildMatchCoach(rich, 'cyruson1001').verdict;
    expect(v.best, isNotNull);
    expect(v.worst, isNotNull);
    expect(v.best!.score!, greaterThan(v.worst!.score!));
  });

  test('the verdict says which way you are heading and gives a plan', () {
    final v = buildMatchCoach(rich, 'cyruson1001').verdict;
    expect(v.headline, startsWith('You are improving'));
    expect(v.plan, isNotEmpty);
    expect(v.plan.length, lessThanOrEqualTo(3));
    expect(v.detail, isNotEmpty);
    expect(v.plan, isNot(contains(v.focus!.drill)), reason: 'the focus card already shows its own drill');
    expect(v.strengths.every((r) => r.title.isNotEmpty), isTrue);
  });

  test('one match alone is compared with a typical player, not with yourself', () {
    final one = asPlayer(series(1, 6, (_) => true), 'cyruson1001');
    final c = buildMatchCoach(one, 'cyruson1001');
    expect(c.reviews.length, 1);
    expect(c.reviews.single.vsUsual, isNull);
    expect(c.verdict.best, isNull);
    expect(c.reviews.single.headline, isNot(contains('usual')));
  });

  test('nothing to coach with no replays', () {
    final c = buildMatchCoach(const [], 'cyruson1001');
    expect(c.reviews, isEmpty);
    expect(c.verdict.headline, contains('Not enough replays'));
    expect(c.verdict.plan, isEmpty);
  });

  test('the report inside the coach is the same one the details use', () {
    final c = buildMatchCoach(rich, 'cyruson1001');
    final r = buildReplayReport(rich, 'cyruson1001');
    expect(c.report.score.score, r.score.score);
    expect(c.report.findings.length, r.findings.length);
  });
}
