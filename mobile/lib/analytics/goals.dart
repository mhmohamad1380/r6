import '../data/snapshots.dart';
import 'insights.dart';

/// A measurable target tracked against snapshots taken after the goal started.
class Goal {
  const Goal({required this.metric, required this.baseline, required this.target, required this.startedAt});
  final GoalMetric metric;
  final double baseline, target;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {'m': metric.name, 'b': baseline, 't': target, 'at': startedAt.toIso8601String()};
  factory Goal.fromJson(Map<String, dynamic> j) => Goal(
        metric: GoalMetric.values.firstWhere((m) => m.name == j['m'], orElse: () => GoalMetric.kd),
        baseline: (j['b'] as num).toDouble(),
        target: (j['t'] as num).toDouble(),
        startedAt: DateTime.parse(j['at'] as String),
      );
}

const minGoalRounds = 30;

String metricLabel(GoalMetric m) => switch (m) {
      GoalMetric.opening => 'Opening duels won',
      GoalMetric.kd => 'K/D',
      GoalMetric.headshot => 'Headshot share',
      GoalMetric.roundWin => 'Round win rate',
      GoalMetric.survival => 'Rounds survived',
      GoalMetric.clutch => 'Clutch conversion',
    };

bool isRatio(GoalMetric m) => m != GoalMetric.kd;

String formatMetric(GoalMetric m, double v) => isRatio(m) ? '${(v * 100).toStringAsFixed(0)}%' : v.toStringAsFixed(2);

Map<String, int> _sum(Snapshot s) {
  final t = <String, int>{};
  for (final o in s.ops.values) {
    for (final e in o.entries) {
      if (e.key == 'att') continue;
      t[e.key] = (t[e.key] ?? 0) + e.value;
    }
  }
  return t;
}

double? _value(GoalMetric m, Map<String, int> t) {
  double? r(int n, int d) => d <= 0 ? null : n / d;
  int g(String k) => t[k] ?? 0;
  return switch (m) {
    GoalMetric.opening => r(g('fb'), g('fb') + g('fd')),
    GoalMetric.kd => r(g('k'), g('d')),
    GoalMetric.headshot => r(g('hs'), g('k')),
    GoalMetric.roundWin => r(g('rw'), g('r')),
    GoalMetric.survival => g('r') == 0 ? null : 1 - g('d') / g('r'),
    GoalMetric.clutch => r(g('c'), g('c') + g('cl')),
  };
}

/// Lifetime value of a metric in one snapshot.
double? lifetimeValue(GoalMetric m, Snapshot s) => _value(m, _sum(s));

/// Sensible target: a modest, reachable step from today's value.
double suggestTarget(GoalMetric m, double baseline) => switch (m) {
      GoalMetric.kd => (baseline + 0.15).clamp(0.0, 3.0),
      GoalMetric.opening => (baseline + 0.10).clamp(0.0, 0.7),
      GoalMetric.headshot => (baseline + 0.07).clamp(0.0, 0.8),
      GoalMetric.roundWin => (baseline + 0.05).clamp(0.0, 0.8),
      GoalMetric.survival => (baseline + 0.07).clamp(0.0, 0.8),
      GoalMetric.clutch => (baseline + 0.07).clamp(0.0, 0.6),
    };

class GoalProgress {
  const GoalProgress({required this.rounds, required this.value});
  final int rounds; // rounds played since the goal started
  final double? value; // metric over those rounds; null until minGoalRounds
  bool get ready => value != null;
}

/// Progress over rounds played since [goal.startedAt]: later snapshot totals minus the
/// last snapshot at or before the start.
GoalProgress progressFor(Goal goal, List<Snapshot> snapshots) {
  if (snapshots.length < 2) return const GoalProgress(rounds: 0, value: null);
  Snapshot start = snapshots.first;
  for (final s in snapshots) {
    if (!s.at.isAfter(goal.startedAt)) start = s;
  }
  final end = snapshots.last;
  final a = _sum(start), b = _sum(end);
  final d = {for (final k in b.keys) k: (b[k] ?? 0) - (a[k] ?? 0)};
  final rounds = d['r'] ?? 0;
  if (rounds < minGoalRounds || d.values.any((v) => v < 0)) return GoalProgress(rounds: rounds < 0 ? 0 : rounds, value: null);
  return GoalProgress(rounds: rounds, value: _value(goal.metric, d));
}
