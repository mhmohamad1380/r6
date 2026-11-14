import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

class TrendPoint {
  const TrendPoint(this.value, this.label, {this.good});
  final double value; // 0-100
  final String label; // shown when the point is touched
  final bool? good; // colors the dot: true green, false red, null accent
}

/// A 0-100 value over time, oldest to newest. Touch or drag to read a point.
class TrendChart extends StatefulWidget {
  const TrendChart({super.key, required this.points, this.height = 150, this.baseline = 50});
  final List<TrendPoint> points;
  final double height;
  final double baseline; // dashed reference line

  @override
  State<TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<TrendChart> {
  int? _sel;

  void _pick(double dx, double w) {
    final n = widget.points.length;
    final i = ((dx / w) * (n - 1)).round().clamp(0, n - 1);
    if (i != _sel) HapticFeedback.selectionClick();
    setState(() => _sel = i);
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points;
    if (pts.length < 2) return const SizedBox.shrink();
    final sel = _sel == null || _sel! >= pts.length ? null : pts[_sel!];
    return Semantics(
      label: 'Score trend over ${pts.length} matches, from ${pts.first.value.round()} to ${pts.last.value.round()}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 22,
          child: Text(
            sel == null ? 'Touch the chart to inspect a match' : '${sel.value.round()} · ${sel.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel == null ? AppColors.textDim : AppColors.text),
          ),
        ),
        LayoutBuilder(
          builder: (_, c) => GestureDetector(
            onTapDown: (d) => _pick(d.localPosition.dx, c.maxWidth),
            onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx.clamp(0, c.maxWidth), c.maxWidth),
            child: SizedBox(height: widget.height, width: double.infinity, child: CustomPaint(painter: _TrendPainter(pts, _sel, widget.baseline))),
          ),
        ),
      ]),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.pts, this.sel, this.baseline);
  final List<TrendPoint> pts;
  final int? sel;
  final double baseline;

  @override
  void paint(Canvas canvas, Size size) {
    final vals = [for (final p in pts) p.value];
    final lo = math.min(vals.reduce(math.min), baseline), hi = math.max(vals.reduce(math.max), baseline);
    final pad = math.max(8.0, (hi - lo) * 0.2);
    final mn = math.max(0.0, lo - pad), mx = math.min(100.0, hi + pad);
    final span = math.max(1.0, mx - mn);
    Offset pt(int i) => Offset(size.width * i / (vals.length - 1), size.height * (1 - (vals[i] - mn) / span));

    final by = size.height * (1 - (baseline - mn) / span);
    final dash = Paint()..color = AppColors.outline..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 10) {
      canvas.drawLine(Offset(x, by), Offset(math.min(x + 5, size.width), by), dash);
    }
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < vals.length; i++) {
      final a = pt(i - 1), b = pt(i), mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    canvas.drawPath(fill, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [AppColors.accent.withValues(alpha: 0.28), AppColors.accent.withValues(alpha: 0)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.6..strokeCap = StrokeCap.round..color = AppColors.accent);
    for (var i = 0; i < vals.length; i++) {
      final g = pts[i].good;
      final col = g == null ? AppColors.accent : (g ? AppColors.good : AppColors.bad);
      canvas.drawCircle(pt(i), i == sel ? 6 : 3.6, Paint()..color = i == sel ? Colors.white : col);
    }
    if (sel != null) {
      final p = pt(sel!);
      canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), Paint()..color = Colors.white24..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_TrendPainter o) => o.sel != sel || o.pts != pts || o.baseline != baseline;
}

class FlowRound {
  const FlowRound({required this.number, required this.kills, required this.died, required this.attack, this.won, this.opening = 0, this.clutch = false});
  final int number, kills;
  final bool died, attack, clutch;
  final bool? won;
  final int opening; // 1 opening kill, -1 opening death, 0 none
}

/// One tile per round: result colour, your kills as dots, a cross if you died, and the side.
class RoundFlow extends StatelessWidget {
  const RoundFlow({super.key, required this.rounds});
  final List<FlowRound> rounds;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 6, runSpacing: 6, children: [for (final r in rounds) _tile(r)]),
        const SizedBox(height: 10),
        const Wrap(spacing: 14, runSpacing: 4, children: [
          _Key(color: AppColors.good, text: 'Won'),
          _Key(color: AppColors.bad, text: 'Lost'),
          _Key(icon: Icons.circle, color: AppColors.text, text: 'Kill'),
          _Key(icon: Icons.close, color: AppColors.bad, text: 'Died'),
          _Key(icon: Icons.bolt, color: AppColors.warn, text: 'Opening kill'),
        ]),
      ]);

  Widget _tile(FlowRound r) {
    final c = r.won == null ? AppColors.textDim : (r.won! ? AppColors.good : AppColors.bad);
    return Semantics(
      label: 'Round ${r.number}, ${r.attack ? 'attack' : 'defense'}, ${r.won == null ? 'result unknown' : (r.won! ? 'won' : 'lost')}, ${r.kills} kills${r.died ? ', died' : ''}',
      child: Container(
        width: 38,
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10), border: Border.all(color: c.withValues(alpha: r.clutch ? 1 : 0.45), width: r.clutch ? 2 : 1)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${r.number}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: c, fontFeatures: tabular)),
          const SizedBox(height: 4),
          SizedBox(
            height: 22,
            child: r.kills == 0
                ? const Center(child: Text('·', style: TextStyle(color: AppColors.textDim)))
                : Wrap(alignment: WrapAlignment.center, runAlignment: WrapAlignment.center, spacing: 2, runSpacing: 2, children: [for (var i = 0; i < math.min(r.kills, 6); i++) Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: i == 0 && r.opening == 1 ? AppColors.warn : AppColors.text))]),
          ),
          const SizedBox(height: 2),
          SizedBox(height: 14, child: r.died ? const Icon(Icons.close, size: 14, color: AppColors.bad) : const Icon(Icons.shield_outlined, size: 12, color: AppColors.textDim)),
          Text(r.attack ? 'A' : 'D', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: r.attack ? AppColors.attack : AppColors.defense)),
        ]),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.color, required this.text, this.icon});
  final Color color;
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        icon == null ? Container(width: 10, height: 10, decoration: BoxDecoration(color: color.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(3), border: Border.all(color: color))) : Icon(icon, size: icon == Icons.circle ? 8 : 13, color: color),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5)),
      ]);
}

/// Kills and deaths per 30-second slice of the round clock.
class TimeHistogram extends StatelessWidget {
  const TimeHistogram({super.key, required this.kills, required this.deaths, required this.labels, this.height = 110});
  final List<int> kills, deaths;
  final List<String> labels;
  final double height;

  @override
  Widget build(BuildContext context) {
    final peak = math.max(1, [...kills, ...deaths].fold<int>(0, math.max));
    return Column(children: [
      SizedBox(
        height: height,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < kills.length; i++)
            Expanded(
              child: Semantics(
                label: '${labels[i]} to ${i + 1 < labels.length ? labels[i + 1] : '0:00'}: ${kills[i]} kills, ${deaths[i]} deaths',
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                  _bar(kills[i], peak, AppColors.good),
                  const SizedBox(width: 3),
                  _bar(deaths[i], peak, AppColors.bad),
                ]),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Row(children: [for (final l in labels) Expanded(child: Center(child: Text(l, style: const TextStyle(color: AppColors.textDim, fontSize: 10.5, fontFeatures: tabular))))]),
      const SizedBox(height: 8),
      const Wrap(spacing: 14, children: [_Key(color: AppColors.good, text: 'Your kills'), _Key(color: AppColors.bad, text: 'Your deaths')]),
    ]);
  }

  Widget _bar(int v, int peak, Color c) => SizedBox(
        width: 16, // fixed, so two bars always fit in a narrow slice
        child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
          if (v > 0) FittedBox(fit: BoxFit.scaleDown, child: Text('$v', style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w800, fontFeatures: tabular))),
          Container(width: 11, height: v == 0 ? 2 : math.max(4.0, (height - 20) * v / peak), decoration: BoxDecoration(color: v == 0 ? AppColors.outline : c, borderRadius: const BorderRadius.vertical(top: Radius.circular(4)))),
        ]),
      );
}

/// A signed change with an arrow: green when it is a good direction, red when not.
class DeltaChip extends StatelessWidget {
  const DeltaChip(this.text, {super.key, required this.up, this.neutral = false});
  final String text;
  final bool up, neutral;

  @override
  Widget build(BuildContext context) {
    final c = neutral ? AppColors.textDim : (up ? AppColors.good : AppColors.bad);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(neutral ? Icons.trending_flat : (up ? Icons.trending_up : Icons.trending_down), size: 14, color: c),
        const SizedBox(width: 4),
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12, fontFeatures: tabular))),
      ]),
    );
  }
}
