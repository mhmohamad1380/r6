import '../analytics/scoring.dart';
import 'models.dart';

/// Cumulative per-operator counters, keyed by short field names to keep stored JSON small.
const _opFields = ['r', 'rw', 'rl', 'k', 'd', 'a', 'hs', 'fb', 'fd', 'c', 'cl', 'k2', 'k3', 'k4', 'k5', 'tk', 'm', 'mw', 'ms'];

Map<String, int> _opCounters(OperatorStat o) => {
      'r': o.roundsPlayed ?? 0,
      'rw': o.roundsWon ?? 0,
      'rl': o.roundsLost ?? 0,
      'k': o.kills ?? 0,
      'd': o.deaths ?? 0,
      'a': o.assists ?? 0,
      'hs': o.headshots ?? 0,
      'fb': o.firstBloods ?? 0,
      'fd': o.firstDeaths ?? 0,
      'c': o.clutches ?? 0,
      'cl': o.clutchesLost ?? 0,
      'k2': o.kills2 ?? 0,
      'k3': o.kills3 ?? 0,
      'k4': o.kills4 ?? 0,
      'k5': o.kills5 ?? 0,
      'tk': o.teamKills ?? 0,
      'm': o.matchesPlayed ?? 0,
      'mw': o.matchesWon ?? 0,
      'ms': o.timePlayedMs ?? 0,
    };

class ModeCounts {
  const ModeCounts({required this.wins, required this.losses, required this.kills, required this.deaths, this.rp});
  final int wins, losses, kills, deaths;
  final int? rp;
  int get matches => wins + losses;

  Map<String, dynamic> toJson() => {'w': wins, 'l': losses, 'k': kills, 'd': deaths, 'rp': rp};
  factory ModeCounts.fromJson(Map<String, dynamic> j) => ModeCounts(
        wins: (j['w'] as num).toInt(),
        losses: (j['l'] as num).toInt(),
        kills: (j['k'] as num).toInt(),
        deaths: (j['d'] as num).toInt(),
        rp: (j['rp'] as num?)?.toInt(),
      );
}

/// A moment-in-time copy of the player's cumulative counters. The difference between two
/// snapshots is what was played in between, which is how per-match detail is derived.
class Snapshot {
  const Snapshot({required this.at, required this.modes, required this.ops, this.rank, this.rankColor});
  final DateTime at;
  final Map<String, ModeCounts> modes; // ranked / standard / casual
  final Map<String, Map<String, int>> ops; // operator -> counters, plus side under key 'att' (1/0)
  final String? rank, rankColor;

  int get totalRounds => ops.values.fold(0, (s, o) => s + (o['r'] ?? 0));

  factory Snapshot.from(PlayerProfile p, List<OperatorStat> ops, {DateTime? at}) => Snapshot(
        at: at ?? DateTime.now(),
        modes: {
          for (final e in p.boards.entries)
            if (e.value.wins != null && e.value.losses != null && e.value.kills != null && e.value.deaths != null)
              e.key: ModeCounts(
                wins: e.value.wins!,
                losses: e.value.losses!,
                kills: e.value.kills!,
                deaths: e.value.deaths!,
                rp: e.key == 'ranked' ? e.value.rankPoints : null,
              ),
        },
        ops: {
          for (final o in ops)
            if ((o.roundsPlayed ?? 0) > 0) o.name: {..._opCounters(o), 'att': o.isAttacker ? 1 : 0},
        },
        rank: p.currentRankName,
        rankColor: p.latestRank?.colorHex,
      );

  bool sameCounters(Snapshot o) {
    if (modes.length != o.modes.length || ops.length != o.ops.length) return false;
    for (final e in modes.entries) {
      final m = o.modes[e.key];
      if (m == null || m.wins != e.value.wins || m.losses != e.value.losses || m.kills != e.value.kills) return false;
    }
    for (final e in ops.entries) {
      final m = o.ops[e.key];
      if (m == null || m['r'] != e.value['r'] || m['k'] != e.value['k'] || m['d'] != e.value['d']) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'rank': rank,
        'col': rankColor,
        'modes': {for (final e in modes.entries) e.key: e.value.toJson()},
        'ops': ops,
      };

  factory Snapshot.fromJson(Map<String, dynamic> j) => Snapshot(
        at: DateTime.parse(j['at'] as String),
        rank: j['rank'] as String?,
        rankColor: j['col'] as String?,
        modes: {
          for (final e in (j['modes'] as Map).entries) e.key as String: ModeCounts.fromJson(Map<String, dynamic>.from(e.value as Map)),
        },
        ops: {
          for (final e in (j['ops'] as Map).entries)
            e.key as String: {for (final f in (e.value as Map).entries) f.key as String: (f.value as num).toInt()},
        },
      );
}

/// What one operator did between two snapshots.
class OpDelta {
  const OpDelta(this.name, this.attacker, this.c);
  final String name;
  final bool attacker;
  final Map<String, int> c;

  int get rounds => c['r'] ?? 0;
  int get kills => c['k'] ?? 0;
  int get deaths => c['d'] ?? 0;
  double? get kd => deaths == 0 ? null : kills / deaths;
}

/// A match (or several, when refreshes were far apart) reconstructed from two snapshots.
class MatchRecord {
  const MatchRecord({
    required this.at,
    required this.since,
    required this.mode,
    required this.matches,
    required this.wins,
    required this.losses,
    required this.rpDelta,
    required this.rpAfter,
    required this.rank,
    required this.totals,
    required this.ops,
  });

  final DateTime at, since;
  final String mode; // ranked | standard | casual | mixed | unknown
  final int matches, wins, losses;
  final int? rpDelta, rpAfter;
  final String? rank;
  final Map<String, int> totals;
  final List<OpDelta> ops;

  /// Exactly one match: every number is that match's own.
  bool get exact => matches == 1;
  bool? get won => matches == 1 ? wins == 1 : null;

  int get rounds => totals['r'] ?? 0;
  int get roundsWon => totals['rw'] ?? 0;
  int get kills => totals['k'] ?? 0;
  int get deaths => totals['d'] ?? 0;
  int get assists => totals['a'] ?? 0;
  int get headshots => totals['hs'] ?? 0;
  int get firstBloods => totals['fb'] ?? 0;
  int get firstDeaths => totals['fd'] ?? 0;
  int get clutches => totals['c'] ?? 0;
  int get clutchesLost => totals['cl'] ?? 0;
  int get multiKills => (totals['k2'] ?? 0) + (totals['k3'] ?? 0) + (totals['k4'] ?? 0) + (totals['k5'] ?? 0);
  double? get kd => deaths == 0 ? null : kills / deaths;

  ScoreResult get score => scoreMatch(MatchStats(
        mode: mode == 'ranked' || mode == 'standard' ? mode : 'ranked',
        roundsPlayed: rounds,
        roundsWon: roundsWon,
        kills: kills,
        deaths: deaths,
        headshots: headshots,
        openingKills: firstBloods,
        openingDeaths: firstDeaths,
      ));
}

/// Diff of two snapshots. Null when nothing was played, or a counter went backwards
/// (data reset / provider correction), in which case the pair cannot be trusted.
MatchRecord? diffSnapshots(Snapshot prev, Snapshot cur) {
  final modeDeltas = <String, (int, int, int?)>{}; // mode -> (wins, losses, rpDelta)
  for (final e in cur.modes.entries) {
    final p = prev.modes[e.key];
    if (p == null) continue;
    final dw = e.value.wins - p.wins, dl = e.value.losses - p.losses;
    if (dw < 0 || dl < 0) return null;
    if (dw + dl > 0) {
      final rp = (e.value.rp != null && p.rp != null) ? e.value.rp! - p.rp! : null;
      modeDeltas[e.key] = (dw, dl, rp);
    }
  }

  final totals = {for (final f in _opFields) f: 0};
  final ops = <OpDelta>[];
  for (final e in cur.ops.entries) {
    final p = prev.ops[e.key];
    final c = <String, int>{};
    for (final f in _opFields) {
      final d = (e.value[f] ?? 0) - (p?[f] ?? 0);
      if (d < 0) return null;
      c[f] = d;
    }
    if (c['r']! > 0 || c['k']! > 0 || c['d']! > 0) {
      ops.add(OpDelta(e.key, e.value['att'] == 1, c));
      for (final f in _opFields) {
        totals[f] = totals[f]! + c[f]!;
      }
    }
  }
  if (ops.isEmpty && modeDeltas.isEmpty) return null;
  ops.sort((a, b) => b.rounds.compareTo(a.rounds));

  var wins = 0, losses = 0;
  int? rpDelta;
  for (final d in modeDeltas.values) {
    wins += d.$1;
    losses += d.$2;
  }
  final ranked = modeDeltas['ranked'];
  if (ranked != null) rpDelta = ranked.$3;
  final mode = modeDeltas.length == 1 ? modeDeltas.keys.first : (modeDeltas.isEmpty ? 'unknown' : 'mixed');
  return MatchRecord(
    at: cur.at,
    since: prev.at,
    mode: mode,
    matches: wins + losses,
    wins: wins,
    losses: losses,
    rpDelta: rpDelta,
    rpAfter: cur.modes['ranked']?.rp,
    rank: cur.rank,
    totals: totals,
    ops: ops,
  );
}

/// Match log from an oldest-first list of snapshots, newest record first.
List<MatchRecord> buildMatchLog(List<Snapshot> snapshots) {
  final out = <MatchRecord>[];
  for (var i = 1; i < snapshots.length; i++) {
    final r = diffSnapshots(snapshots[i - 1], snapshots[i]);
    if (r != null) out.add(r);
  }
  return out.reversed.toList();
}
