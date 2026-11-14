import 'rp.dart';

/// A stretch of ranked play separated from the next by a long break.
class PlaySession {
  const PlaySession({required this.games, required this.start, required this.end});
  final List<RpDelta> games; // oldest first
  final DateTime start, end;

  int get wins => games.where((g) => g.win).length;
  int get losses => games.length - wins;
  int get net => games.fold(0, (s, g) => s + g.delta);
  Duration get length => end.difference(start);
  RpDelta get best => games.reduce((a, b) => a.delta >= b.delta ? a : b);
  RpDelta get worst => games.reduce((a, b) => a.delta <= b.delta ? a : b);

  /// RP in the first half versus the second half. Null when too short to compare.
  (int, int)? get halves {
    if (games.length < 4) return null;
    final h = games.length ~/ 2;
    int sum(Iterable<RpDelta> x) => x.fold(0, (s, g) => s + g.delta);
    return (sum(games.take(h)), sum(games.skip(games.length - h)));
  }

  /// A fatigue note only when the data supports it: a clearly worse second half.
  String? get note {
    final h = halves;
    if (h != null && h.$2 <= h.$1 - 60 && games.length >= 6) {
      return 'You gained ${h.$1} RP in the first half and ${h.$2} in the second. Consider stopping earlier or taking a break mid-session.';
    }
    if (h != null && h.$2 >= h.$1 + 60 && games.length >= 6) return 'You got better as the session went on.';
    return null;
  }
}

/// Groups RP-inferred games into sessions. [gap] is the longest pause inside one session.
List<PlaySession> sessionsFromRp(List<RpDelta> newestFirst, {Duration gap = const Duration(hours: 2)}) {
  if (newestFirst.isEmpty) return const [];
  final asc = newestFirst.reversed.toList();
  final out = <PlaySession>[];
  var cur = <RpDelta>[asc.first];
  for (var i = 1; i < asc.length; i++) {
    if (asc[i].at.difference(asc[i - 1].at) > gap) {
      out.add(PlaySession(games: cur, start: cur.first.at, end: cur.last.at));
      cur = [];
    }
    cur.add(asc[i]);
  }
  out.add(PlaySession(games: cur, start: cur.first.at, end: cur.last.at));
  return out.reversed.toList(); // newest session first
}
