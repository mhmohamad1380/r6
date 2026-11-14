import '../data/scope.dart';
import 'stats.dart';

/// Weights and reference values are design assumptions, not validated constants.
/// A component is null when its inputs are missing; null is never treated as 0.
const scoringVersion = '0.1.0';

class MatchStats {
  const MatchStats({
    this.mode = 'ranked',
    this.roundsPlayed,
    this.roundsWon,
    this.kills,
    this.deaths,
    this.headshots,
    this.openingKills,
    this.openingDeaths,
  });

  final String mode;
  final int? roundsPlayed, roundsWon, kills, deaths, headshots, openingKills, openingDeaths;
}

class _ModeConfig {
  const _ModeConfig(this.weights);
  final Map<String, double> weights;
}

const _configs = <String, _ModeConfig>{
  'ranked': _ModeConfig({'mechanical': 0.30, 'tactical': 0.35, 'objective': 0.35}),
  'standard': _ModeConfig({'mechanical': 0.35, 'tactical': 0.30, 'objective': 0.35}),
  'quick_match': _ModeConfig({'mechanical': 0.50, 'tactical': 0.25, 'objective': 0.25}),
  'team_deathmatch': _ModeConfig({'mechanical': 0.80, 'tactical': 0.10, 'objective': 0.10}),
};

const _kdRef = (1.0, 0.35);
const _hsRef = (0.45, 0.15);
const _openingRef = (0.0, 0.25);

class ScoreResult {
  const ScoreResult({
    required this.score,
    required this.components,
    required this.confidence,
    required this.provisional,
    this.notes = const [],
  });

  final double? score;
  final Map<String, double?> components;
  final String confidence;
  final bool provisional;
  final List<String> notes;
  String get version => scoringVersion;
}

String confidenceLabel(int? rounds, int available, [int total = 3]) {
  if (rounds == null || rounds == 0 || available == 0) return 'low';
  final coverage = available / total;
  if (rounds >= 60 && coverage >= 0.75) return 'high';
  if (rounds >= 20 && coverage >= 0.5) return 'medium';
  return 'low';
}

double? _mechanical(MatchStats m) {
  final parts = <double>[];
  if (m.kills != null && m.deaths != null && (m.roundsPlayed ?? 0) > 0) {
    final d = m.deaths! < 1 ? 1 : m.deaths!; // floor avoids infinite ratios
    parts.add(normalize(m.kills! / d, _kdRef.$1, _kdRef.$2));
  }
  if (m.headshots != null && (m.kills ?? 0) > 0) {
    parts.add(normalize(m.headshots! / m.kills!, _hsRef.$1, _hsRef.$2));
  }
  return parts.isEmpty ? null : parts.reduce((a, b) => a + b) / parts.length;
}

double? _tactical(MatchStats m) {
  if (m.openingKills == null || m.openingDeaths == null) return null;
  final duels = m.openingKills! + m.openingDeaths!;
  if (duels == 0) return null;
  return normalize((m.openingKills! - m.openingDeaths!) / duels, _openingRef.$1, _openingRef.$2);
}

double? _objective(MatchStats m) {
  if (m.roundsWon == null || (m.roundsPlayed ?? 0) == 0) return null;
  return 100 * bayesRate(m.roundsWon!, m.roundsPlayed!);
}

double _round1(double v) => (v * 10).round() / 10;

ScoreResult scoreMatch(MatchStats m) {
  final notes = <String>[];
  var cfg = _configs[m.mode];
  if (cfg == null) {
    cfg = _configs['ranked']!;
    notes.add("No config for mode '${m.mode}'; used ranked weights.");
  }
  final components = <String, double?>{
    'mechanical': _mechanical(m),
    'tactical': _tactical(m),
    'objective': _objective(m),
  };
  final available = {
    for (final e in components.entries)
      if (e.value != null) e.key: e.value!,
  };
  for (final e in components.entries) {
    if (e.value == null) notes.add('${e.key} unavailable: required data missing.');
  }
  if (available.isEmpty) {
    return ScoreResult(score: null, components: components, confidence: 'low', provisional: true, notes: notes);
  }
  final totalW = available.keys.fold<double>(0, (s, k) => s + cfg!.weights[k]!);
  final score = available.entries.fold<double>(0, (s, e) => s + cfg!.weights[e.key]! * e.value) / totalW;
  return ScoreResult(
    score: _round1(score),
    components: {for (final e in components.entries) e.key: e.value == null ? null : _round1(e.value!)},
    confidence: confidenceLabel(m.roundsPlayed, available.length, components.length),
    provisional: available.length < components.length,
    notes: notes,
  );
}

/// Which scoring weights apply to a mode filter. Mixed views use the ranked weights.
String scoringMode(ModeFilter m) => switch (m) {
      ModeFilter.quick => 'quick_match',
      ModeFilter.standard || ModeFilter.unranked => 'standard',
      _ => 'ranked',
    };
