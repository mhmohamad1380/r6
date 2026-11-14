import '../data/models.dart';

class Totals {
  const Totals(this.label, this.operators, this.rounds, this.roundsWon, this.kills, this.deaths, this.headshots, this.fb, this.fd, this.assists, this.timeMs);
  final String label;
  final int operators, rounds, roundsWon, kills, deaths, headshots, fb, fd, assists, timeMs;

  double? get kd => deaths == 0 ? null : kills / deaths;
  double? get roundWinRate => rounds == 0 ? null : roundsWon / rounds;
  double? get headshotRate => kills == 0 ? null : headshots / kills;
  double? get opening => (fb + fd) == 0 ? null : fb / (fb + fd);
  double? get killsPerRound => rounds == 0 ? null : kills / rounds;
  double? get survival => rounds == 0 ? null : 1 - deaths / rounds;

  static Totals of(String label, Iterable<OperatorStat> ops) {
    int s(int? Function(OperatorStat) f) => ops.fold(0, (a, o) => a + (f(o) ?? 0));
    return Totals(label, ops.length, s((o) => o.roundsPlayed), s((o) => o.roundsWon), s((o) => o.kills), s((o) => o.deaths),
        s((o) => o.headshots), s((o) => o.firstBloods), s((o) => o.firstDeaths), s((o) => o.assists), s((o) => o.timePlayedMs));
  }
}

Totals sideTotals(List<OperatorStat> ops, bool attacker) =>
    Totals.of(attacker ? 'Attack' : 'Defense', ops.where((o) => o.isAttacker == attacker));

/// Roles overlap (an operator can be "Anchor" and "Intel Denier"), so role rows do not sum to the total.
List<Totals> roleTotals(List<OperatorStat> ops, List<GameOperator> game) {
  final byName = {for (final g in game) g.key: g};
  final groups = <String, List<OperatorStat>>{};
  for (final o in ops) {
    for (final r in byName[o.name.toLowerCase()]?.roles ?? const <String>[]) {
      groups.putIfAbsent(r, () => []).add(o);
    }
  }
  return [for (final e in groups.entries) Totals.of(e.key, e.value)]..sort((a, b) => b.rounds.compareTo(a.rounds));
}

/// How concentrated the operator pool is.
class PoolStats {
  const PoolStats({required this.played, required this.regulars, required this.available, required this.top3Share, required this.top1, required this.top1Share});
  final int played, regulars, available;
  final double top3Share, top1Share;
  final String? top1;
}

PoolStats poolStats(List<OperatorStat> ops, List<GameOperator> game) {
  final sorted = [...ops]..sort((a, b) => (b.roundsPlayed ?? 0).compareTo(a.roundsPlayed ?? 0));
  final total = sorted.fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
  final top3 = sorted.take(3).fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
  return PoolStats(
    played: sorted.where((o) => (o.roundsPlayed ?? 0) > 0).length,
    regulars: sorted.where((o) => (o.roundsPlayed ?? 0) >= 30).length,
    available: game.length,
    top3Share: total == 0 ? 0 : top3 / total,
    top1: sorted.isEmpty ? null : sorted.first.name,
    top1Share: total == 0 || sorted.isEmpty ? 0 : (sorted.first.roundsPlayed ?? 0) / total,
  );
}

class ModeRow {
  const ModeRow(this.id, this.label, this.board, this.segment);
  final String id, label;
  final ModeBoard? board;
  final SeasonSegment? segment;

  int? get matches => board?.matches ?? segment?.stat('matchesPlayed')?.toInt();
  double? get winRate => board?.winRate ?? ((segment?.stat('matchesWon') != null && (matches ?? 0) > 0) ? segment!.stat('matchesWon')! / matches! : null);
  double? get kd => board?.kd ?? segment?.stat('kdRatio')?.toDouble();
  int? get hours {
    final t = segment?.stat('timePlayed');
    return t == null ? null : (t / 3600000).round();
  }
}

List<ModeRow> modeRows(PlayerProfile p) {
  SeasonSegment? seg(String type) {
    for (final s in p.segments) {
      if (s.sessionType == type && s.shortName != null) return s;
    }
    return null;
  }

  return [
    ModeRow('ranked', 'Ranked', p.boards['ranked'], seg('ranked')),
    ModeRow('standard', 'Standard', p.boards['standard'], seg('standard')),
    ModeRow('casual', 'Quick Match', p.boards['casual'], seg('quick-match')),
  ].where((m) => (m.matches ?? 0) > 0).toList();
}

/// Multi-kill rounds per 100 rounds played.
double? multiKillRate(List<OperatorStat> ops) {
  final rounds = ops.fold<int>(0, (s, o) => s + (o.roundsPlayed ?? 0));
  if (rounds == 0) return null;
  final mk = ops.fold<int>(0, (s, o) => s + (o.kills2 ?? 0) + (o.kills3 ?? 0) + (o.kills4 ?? 0) + (o.kills5 ?? 0));
  return 100 * mk / rounds;
}
