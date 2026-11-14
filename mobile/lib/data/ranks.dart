import 'dart:convert';

class RankBand {
  const RankBand(this.name, this.min, this.max);
  final String name;
  final int min, max; // inclusive RP bounds
  bool get isTop => max >= 100000;
  int get width => max - min + 1;
}

/// Ranked RP bands (Arenyze /ranks?version=v7, bundled so it costs no API calls).
class RankLadder {
  const RankLadder(this.bands);
  static const empty = RankLadder([]);
  final List<RankBand> bands;

  factory RankLadder.parse(String json) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    return RankLadder([
      for (final r in j['ranks'] as List) RankBand(r['n'] as String, (r['min'] as num).toInt(), (r['max'] as num).toInt()),
    ]);
  }

  RankBand? bandFor(int rp) {
    for (final b in bands) {
      if (rp >= b.min && rp <= b.max) return b;
    }
    return null;
  }

  RankBand? next(RankBand b) {
    final i = bands.indexOf(b);
    return (i < 0 || i + 1 >= bands.length) ? null : bands[i + 1];
  }

  RankBand? previous(RankBand b) {
    final i = bands.indexOf(b);
    return (i <= 0) ? null : bands[i - 1];
  }
}
