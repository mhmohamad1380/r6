import 'insights.dart';
import 'replay_stats.dart';

/// Findings from imported replays. Each needs a minimum number of rounds and states it.
List<Insight> replayInsights(List<MyRound> all) {
  final mine = all.where((r) => r.present).toList();
  final out = <Insight>[];
  if (mine.length < 8) return out;
  final s = summarize(mine);
  String pc(double v) => '${(v * 100).toStringAsFixed(0)}%';

  // Dying alone: few deaths are avenged by a teammate.
  if (s.deaths >= 8 && s.avengedRate != null && s.avengedRate! < 0.3) {
    out.add(Insight(
        id: 'replay-alone', category: 'Replays', title: 'You usually die without a teammate answering',
        evidence: 'Only ${s.avengedDeaths} of your ${s.deaths} deaths were avenged by a teammate (${pc(s.avengedRate!)}) over ${s.rounds} replay rounds.',
        action: 'Stay close enough that a teammate can punish whoever kills you. A death that is traded costs the round far less.',
        drill: 'In your next ranked games, stay within one room of a teammate until the first contact happens.',
        sample: s.rounds, tone: Tone.warn, unit: 'rounds'));
  }

  // Opening duels measured round by round.
  final duels = s.openingKills + s.openingDeaths;
  if (duels >= 8 && s.openingRate != null && s.openingRate! < 0.4) {
    out.add(Insight(
        id: 'replay-opening', category: 'Replays', title: 'Your replays confirm it: you lose opening duels',
        evidence: 'In ${s.rounds} replay rounds you won ${s.openingKills} of $duels opening duels (${pc(s.openingRate!)}).',
        action: 'Open the replay of a round where you died first and look at where you were standing and who knew you were there.',
        drill: 'Before you peek, ask whether a teammate or a drone has already seen that angle.',
        sample: s.rounds, tone: Tone.warn, unit: 'rounds'));
  }

  // Side gap.
  List<MyRound> side(bool atk) => mine.where((r) => r.attack == atk && r.won != null).toList();
  final atk = side(true), def = side(false);
  if (atk.length >= 6 && def.length >= 6) {
    final a = atk.where((r) => r.won == true).length / atk.length, d = def.where((r) => r.won == true).length / def.length;
    if ((a - d).abs() >= 0.25) {
      final better = a > d ? 'attack' : 'defense';
      out.add(Insight(
          id: 'replay-side', category: 'Replays', title: 'Your team wins far more on $better',
          evidence: 'Attack: ${pc(a)} over ${atk.length} rounds. Defense: ${pc(d)} over ${def.length}.',
          action: 'Look at how your weaker side starts its rounds: first plays, utility and who takes the first fight.',
          sample: atk.length + def.length, tone: Tone.info, unit: 'rounds'));
    }
  }

  // Weakest bombsite.
  final weak = siteStats(mine).where((x) => x.rounds >= 4 && x.winRate <= 0.25).toList();
  if (weak.isNotEmpty) {
    final w = weak.first;
    out.add(Insight(
        id: 'replay-site', category: 'Replays', title: 'You rarely win on ${w.site}',
        evidence: '${w.map} (${w.attack ? 'attack' : 'defense'}), ${w.site}: ${w.wins} wins in ${w.rounds} rounds.',
        action: 'Review those rounds. Is it the setup, the entry or the plant timing that breaks down?',
        drill: 'Play two custom rounds on ${w.map} from this side, only on ${w.site}.',
        sample: w.rounds, tone: Tone.warn, unit: 'rounds'));
  }
  return out;
}
