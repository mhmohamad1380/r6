import 'models.dart';

/// Which game mode the numbers cover. "Unranked" is not fetched: it is All minus Ranked, so it
/// costs nothing beyond the Ranked set.
enum ModeFilter { all, ranked, unranked, standard, quick }

enum Period { lifetime, season }

extension ModeFilterX on ModeFilter {
  String get label => switch (this) {
        ModeFilter.all => 'All',
        ModeFilter.ranked => 'Ranked',
        ModeFilter.unranked => 'Unranked',
        ModeFilter.standard => 'Standard',
        ModeFilter.quick => 'Quick Match',
      };

  /// Value for the API's `modes` parameter; null when derived locally.
  String? get apiMode => switch (this) {
        ModeFilter.all => 'all',
        ModeFilter.ranked => 'ranked',
        ModeFilter.unranked => null,
        ModeFilter.standard => 'standard',
        ModeFilter.quick => 'quick-match',
      };

  String get hint => switch (this) {
        ModeFilter.all => 'Every mode',
        ModeFilter.ranked => 'Ranked only',
        ModeFilter.unranked => 'Everything except Ranked',
        ModeFilter.standard => 'Standard only',
        ModeFilter.quick => 'Quick Match only',
      };
}

String scopeKey(String apiMode, Period p) => '$apiMode|${p.name}';

/// Sets that must be loaded before [m] can be shown for [p].
List<String> keysNeeded(ModeFilter m, Period p) =>
    m == ModeFilter.unranked ? [scopeKey('all', p), scopeKey('ranked', p)] : [scopeKey(m.apiMode!, p)];

int? _sub(int? a, int? b) => a == null ? null : (b == null ? a : a - b);

/// [whole] minus [part], per operator. Operators with no rounds left are dropped. A negative
/// result means the two sets were fetched at different times, so the row is clamped at zero.
List<OperatorStat> subtractOps(List<OperatorStat> whole, List<OperatorStat> part) {
  final byName = {for (final o in part) o.name: o};
  final out = <OperatorStat>[];
  for (final a in whole) {
    final b = byName[a.name];
    int? d(int? Function(OperatorStat) f) {
      final v = _sub(f(a), b == null ? null : f(b));
      return v == null ? null : (v < 0 ? 0 : v);
    }

    final rounds = d((o) => o.roundsPlayed);
    if ((rounds ?? 0) <= 0) continue;
    out.add(OperatorStat(
      name: a.name,
      side: a.side,
      roundsPlayed: rounds,
      roundsWon: d((o) => o.roundsWon),
      roundsLost: d((o) => o.roundsLost),
      kills: d((o) => o.kills),
      deaths: d((o) => o.deaths),
      headshots: d((o) => o.headshots),
      firstBloods: d((o) => o.firstBloods),
      firstDeaths: d((o) => o.firstDeaths),
      clutches: d((o) => o.clutches),
      clutchesLost: d((o) => o.clutchesLost),
      assists: d((o) => o.assists),
      matchesPlayed: d((o) => o.matchesPlayed),
      matchesWon: d((o) => o.matchesWon),
      matchesLost: d((o) => o.matchesLost),
      kills2: d((o) => o.kills2),
      kills3: d((o) => o.kills3),
      kills4: d((o) => o.kills4),
      kills5: d((o) => o.kills5),
      teamKills: d((o) => o.teamKills),
      timePlayedMs: d((o) => o.timePlayedMs),
    ));
  }
  return out;
}
