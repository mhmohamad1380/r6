import 'dart:math' as math;

/// Posterior mean of a beta-binomial model (uniform prior by default).
double bayesRate(int successes, int trials, {double alpha = 1, double beta = 1}) =>
    (successes + alpha) / (trials + alpha + beta);

/// Wilson score interval; stays inside [0, 1] and behaves for small samples.
(double, double) wilsonInterval(int successes, int trials, {double z = 1.96}) {
  if (trials == 0) return (0, 1);
  final p = successes / trials;
  final denom = 1 + z * z / trials;
  final centre = (p + z * z / (2 * trials)) / denom;
  final half = z * math.sqrt(p * (1 - p) / trials + z * z / (4 * trials * trials)) / denom;
  return (math.max(0, centre - half), math.min(1, centre + half));
}

double _erf(double x) {
  // Abramowitz-Stegun 7.1.26, max error ~1.5e-7.
  final s = x < 0 ? -1.0 : 1.0;
  final ax = x.abs();
  final t = 1 / (1 + 0.3275911 * ax);
  final y = 1 -
      (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) *
          t *
          math.exp(-ax * ax);
  return s * y;
}

/// Maps a z-score to 0-100 through the normal CDF (z = 0 -> 50).
double zToScore(double z) => 100 * 0.5 * (1 + _erf(z / math.sqrt2));

double normalize(double value, double mean, double sd) {
  if (sd <= 0) throw ArgumentError('sd must be positive');
  return zToScore((value - mean) / sd);
}

/// 0-100, higher means steadier. Null when there is too little data.
double? consistencyIndex(List<double> scores, {int minMatches = 5}) {
  if (scores.length < minMatches) return null;
  final mean = scores.reduce((a, b) => a + b) / scores.length;
  if (mean <= 0) return null;
  final variance = scores.map((s) => (s - mean) * (s - mean)).reduce((a, b) => a + b) / scores.length;
  final cv = math.sqrt(variance) / mean;
  return math.max(0, 100 * (1 - math.min(cv, 1)));
}
