import '../data/match_notes.dart';
import '../data/snapshots.dart';
import 'insights.dart';

/// Results for one group (a map, a party size, a mood) from matches the player annotated.
class GroupResult {
  const GroupResult(this.label, this.games, this.wins, this.kills, this.deaths);
  final String label;
  final int games, wins, kills, deaths;

  int get losses => games - wins;
  double get winRate => games == 0 ? 0 : wins / games;
  double? get kd => deaths == 0 ? null : kills / deaths;
}

typedef NoteLookup = MatchNote? Function(MatchRecord);

/// Only exact single matches count: a merged entry cannot be assigned to one map or party.
List<MatchRecord> annotatedExact(List<MatchRecord> log, NoteLookup noteFor) => [
      for (final r in log)
        if (r.exact && noteFor(r) != null && !noteFor(r)!.isEmpty) r,
    ];

List<GroupResult> _group(List<MatchRecord> log, NoteLookup noteFor, String? Function(MatchNote) keyOf, {String Function(String)? label}) {
  final groups = <String, List<MatchRecord>>{};
  for (final r in annotatedExact(log, noteFor)) {
    final k = keyOf(noteFor(r)!);
    if (k != null) groups.putIfAbsent(k, () => []).add(r);
  }
  final out = [
    for (final e in groups.entries)
      GroupResult(label == null ? e.key : label(e.key), e.value.length, e.value.where((r) => r.won == true).length, e.value.fold(0, (s, r) => s + r.kills), e.value.fold(0, (s, r) => s + r.deaths)),
  ]..sort((a, b) => b.games.compareTo(a.games));
  return out;
}

List<GroupResult> byMap(List<MatchRecord> log, NoteLookup n) => _group(log, n, (x) => x.map);

List<GroupResult> byParty(List<MatchRecord> log, NoteLookup n) {
  final r = _group(log, n, (x) => x.party, label: partyLabel);
  int order(String l) => partySizes.indexWhere((p) => partyLabel(p) == l);
  return r..sort((a, b) => order(a.label).compareTo(order(b.label)));
}

/// Groups moods into "low" (1-2), "ok" (3) and "high" (4-5).
List<GroupResult> byFeeling(List<MatchRecord> log, NoteLookup n) {
  final r = _group(log, n, (x) => x.feeling == null ? null : (x.feeling! <= 2 ? 'Tilted or tired' : (x.feeling! == 3 ? 'Okay' : 'Locked in')));
  const order = ['Tilted or tired', 'Okay', 'Locked in'];
  return r..sort((a, b) => order.indexOf(a.label).compareTo(order.indexOf(b.label)));
}

/// Findings from the annotated matches. Each needs a minimum number of games per side.
List<Insight> contextInsights(List<MatchRecord> log, NoteLookup n) {
  final out = <Insight>[];
  String pc(double v) => '${(v * 100).toStringAsFixed(0)}%';

  final maps = byMap(log, n).where((g) => g.games >= 5).toList()..sort((a, b) => b.winRate.compareTo(a.winRate));
  if (maps.length >= 2 && maps.first.winRate - maps.last.winRate >= 0.25) {
    final b = maps.first, w = maps.last;
    out.add(Insight(
        id: 'map-gap', category: 'Maps', title: '${w.label} is your weakest map',
        evidence: '${w.label}: ${pc(w.winRate)} wins over ${w.games} matches. ${b.label}: ${pc(b.winRate)} over ${b.games}.',
        action: 'Review your last losses on ${w.label}, and think about the operator and site you pick there.',
        drill: 'Play two custom-game rounds on ${w.label} just to learn the main rotations and sightlines.',
        sample: w.games + b.games, tone: Tone.warn, unit: 'matches'));
  }

  final party = byParty(log, n);
  final solo = party.where((g) => g.label == partyLabel('solo')).toList();
  final stack = party.where((g) => g.label != partyLabel('solo')).toList();
  if (solo.isNotEmpty && stack.isNotEmpty) {
    final sg = solo.first.games, tg = stack.fold<int>(0, (s, g) => s + g.games);
    final sw = solo.first.wins, tw = stack.fold<int>(0, (s, g) => s + g.wins);
    if (sg >= 5 && tg >= 5) {
      final a = sw / sg, b = tw / tg;
      if ((a - b).abs() >= 0.2) {
        final soloBetter = a > b;
        out.add(Insight(
            id: 'party-gap', category: 'Team', title: soloBetter ? 'You win more solo than in a stack' : 'You win more with a team',
            evidence: 'Solo: ${pc(a)} over $sg matches. With others: ${pc(b)} over $tg.',
            action: soloBetter ? 'Your stacks may lack a clear plan. Agree an operator and site plan before queueing.' : 'Solo queue costs you. Use more pings and keep calls short and early.',
            drill: soloBetter ? 'Before each round with friends, name one thing each person will do.' : 'In solo queue, call enemy positions in the first 20 seconds and keep to one plan.',
            sample: sg + tg, tone: Tone.info, unit: 'matches'));
      }
    }
  }

  final mood = byFeeling(log, n);
  final low = mood.where((g) => g.label == 'Tilted or tired').toList();
  final high = mood.where((g) => g.label == 'Locked in').toList();
  if (low.isNotEmpty && high.isNotEmpty && low.first.games >= 4 && high.first.games >= 4) {
    final a = low.first.winRate, b = high.first.winRate;
    if (b - a >= 0.2) {
      out.add(Insight(
          id: 'mood-gap', category: 'Mindset', title: 'Tired or tilted games cost you',
          evidence: 'You win ${pc(b)} when locked in (${high.first.games} matches) and ${pc(a)} when tired or tilted (${low.first.games}).',
          action: 'Treat your mood as part of your setup: stop after two tilted games.',
          drill: 'Set a rule: two losses in a row while tilted means a 15-minute break.',
          sample: low.first.games + high.first.games, tone: Tone.warn, unit: 'matches'));
    }
  }
  return out;
}
