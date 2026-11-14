import '../data/replay.dart';

/// Who the replays belong to, worked out from the replays themselves, so no name has to be typed.
class DetectedPlayer {
  const DetectedPlayer(this.name, this.how, this.rounds);
  final String name;
  final String how; // recorded: the game says whose replay it is. common: the one person in every round of several matches
  final int rounds;
}

/// The player the replays were recorded by. Each file says which profile recorded it, and that is
/// you, because the files come from your own PC. For older saved rounds that lack it, the one name that
/// is in every round of at least two matches is used, and only when nobody else is in them as often.
DetectedPlayer? detectPlayer(List<ReplayRound> rounds) {
  if (rounds.isEmpty) return null;

  // 1. The recording profile.
  final byProfile = <String, int>{};
  for (final r in rounds) {
    if (r.recorder != null && r.recorder!.isNotEmpty) byProfile[r.recorder!] = (byProfile[r.recorder!] ?? 0) + 1;
  }
  if (byProfile.isNotEmpty) {
    final top = byProfile.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    // Their current name: from the newest round they recorded, in case they renamed.
    final mine = [for (final r in rounds) if (r.recorder == top) r]..sort((a, b) => (b.at ?? DateTime(1970)).compareTo(a.at ?? DateTime(1970)));
    for (final r in mine) {
      for (final p in r.players) {
        if (p.profileId == top) return DetectedPlayer(p.name, 'recorded', byProfile[top]!);
      }
    }
  }

  // 2. The one name in every round.
  if ({for (final r in rounds) r.matchId}.length < 2) return null; // one match shows ten equal candidates
  final count = <String, int>{};
  for (final r in rounds) {
    for (final n in {for (final p in r.players) p.name}) {
      count[n] = (count[n] ?? 0) + 1;
    }
  }
  final sorted = count.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final top = sorted.first;
  if (top.value / rounds.length < 0.9) return null;
  if (sorted.length > 1 && sorted[1].value / rounds.length >= 0.8) return null; // a party that always plays together: cannot tell
  return DetectedPlayer(top.key, 'common', top.value);
}

/// Whether a name is one of the players in these replays.
bool appearsIn(List<ReplayRound> rounds, String name) {
  final n = name.trim().toLowerCase();
  if (n.isEmpty) return false;
  return rounds.any((r) => r.players.any((p) => p.name.toLowerCase() == n));
}
