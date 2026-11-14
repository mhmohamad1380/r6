import '../data/snapshots.dart';
import 'rp.dart';

class WeekRecap {
  const WeekRecap({required this.games, required this.wins, required this.net, required this.days, this.bestDay});
  final int games, wins, net, days;
  final String? bestDay; // weekday name with the most RP gained
  int get losses => games - wins;
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

/// Ranked results in the last seven days. Null when there are fewer than 3 games.
WeekRecap? weekRecap(List<RpDelta> games, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final recent = games.where((g) => n.difference(g.at) <= const Duration(days: 7)).toList();
  if (recent.length < 3) return null;
  final byDay = <int, int>{};
  for (final g in recent) {
    final d = g.at.toLocal().weekday;
    byDay[d] = (byDay[d] ?? 0) + g.delta;
  }
  final best = byDay.entries.reduce((a, b) => a.value >= b.value ? a : b);
  return WeekRecap(
    games: recent.length,
    wins: recent.where((g) => g.win).length,
    net: recent.fold(0, (s, g) => s + g.delta),
    days: byDay.length,
    bestDay: best.value > 0 ? _weekdays[best.key - 1] : null,
  );
}

/// Your last tracked matches against your career numbers.
class RecentForm {
  const RecentForm({required this.matches, required this.kd, required this.winRate, required this.headshotRate, required this.openingRate});
  final int matches;
  final double? kd, winRate, headshotRate, openingRate;
}

RecentForm? recentForm(List<MatchRecord> newestFirst, {int last = 10, int minMatches = 3}) {
  final exact = newestFirst.where((r) => r.exact).take(last).toList();
  if (exact.length < minMatches) return null;
  int sum(int Function(MatchRecord) f) => exact.fold(0, (s, r) => s + f(r));
  final k = sum((r) => r.kills), d = sum((r) => r.deaths), hs = sum((r) => r.headshots), fb = sum((r) => r.firstBloods), fd = sum((r) => r.firstDeaths);
  final wins = exact.where((r) => r.won == true).length;
  return RecentForm(
    matches: exact.length,
    kd: d == 0 ? null : k / d,
    winRate: wins / exact.length,
    headshotRate: k == 0 ? null : hs / k,
    openingRate: (fb + fd) == 0 ? null : fb / (fb + fd),
  );
}
