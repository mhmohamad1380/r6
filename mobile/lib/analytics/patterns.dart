import 'rp.dart';

/// Results in one part of the day.
class TimeBlock {
  const TimeBlock(this.label, this.range, this.games, this.wins, this.net);
  final String label, range;
  final int games, wins, net;
  double get winRate => games == 0 ? 0 : wins / games;
}

const _blocks = [
  ('Morning', '5:00-12:00', 5, 12),
  ('Afternoon', '12:00-17:00', 12, 17),
  ('Evening', '17:00-22:00', 17, 22),
  ('Night', '22:00-5:00', 22, 29),
];

/// Ranked games grouped by local time of day, inferred from RP changes.
List<TimeBlock> byTimeOfDay(List<RpDelta> games) {
  final acc = {for (final b in _blocks) b.$1: [0, 0, 0]}; // games, wins, net
  for (final g in games) {
    final t = g.at.toLocal();
    final h = t.hour < 5 ? t.hour + 24 : t.hour;
    final b = _blocks.firstWhere((b) => h >= b.$3 && h < b.$4);
    final a = acc[b.$1]!;
    a[0]++;
    if (g.win) a[1]++;
    a[2] += g.delta;
  }
  return [for (final b in _blocks) TimeBlock(b.$1, b.$2, acc[b.$1]![0], acc[b.$1]![1], acc[b.$1]![2])];
}

/// The clearest gap between two parts of the day, only when both have enough games.
({TimeBlock best, TimeBlock worst})? timeGap(List<TimeBlock> blocks, {int minGames = 8, double minGap = 0.25}) {
  final ok = blocks.where((b) => b.games >= minGames).toList()..sort((a, b) => b.winRate.compareTo(a.winRate));
  if (ok.length < 2) return null;
  return ok.first.winRate - ok.last.winRate >= minGap ? (best: ok.first, worst: ok.last) : null;
}
