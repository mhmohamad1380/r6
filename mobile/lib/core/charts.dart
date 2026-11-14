import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../analytics/skills.dart';
import '../analytics/rp.dart';
import '../data/models.dart';
import 'theme.dart';

/// Circular score gauge, 0-100.
class GaugeRing extends StatelessWidget {
  const GaugeRing({super.key, required this.value, this.size = 120, this.label, this.color});
  final double? value;
  final double size;
  final String? label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? _scoreColor(value);
    return Semantics(
      label: value == null ? 'Score unavailable' : 'Score ${value!.toStringAsFixed(0)} out of 100',
      excludeSemantics: true,
      child: SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: (value ?? 0) / 100),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (_, t, _) => CustomPaint(
          painter: _GaugePainter(t, c, value != null),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(value == null ? '—' : (t * 100).round().toString(), style: TextStyle(fontSize: size * 0.32, fontWeight: FontWeight.w900, fontFeatures: tabular, height: 1)),
              if (label != null) Text(label!, style: TextStyle(fontSize: size * 0.1, color: AppColors.textDim)),
            ]),
          ),
        ),
      ),
      ),
    );
  }
}

Color _scoreColor(double? v) => v == null ? AppColors.textDim : (v >= 60 ? AppColors.good : (v >= 40 ? AppColors.warn : AppColors.bad));
Color scoreColor(double? v) => _scoreColor(v);

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.t, this.color, this.has);
  final double t;
  final Color color;
  final bool has;

  @override
  void paint(Canvas canvas, Size size) {
    final sw = size.width * 0.085; // stroke scales with the gauge so small ones stay clean
    final r = size.width / 2 - sw;
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: r);
    final base = Paint()..style = PaintingStyle.stroke..strokeWidth = sw..strokeCap = StrokeCap.round..color = AppColors.surfaceHi;
    canvas.drawArc(rect, math.pi * 0.75, math.pi * 1.5, false, base);
    if (has) {
      final p = Paint()..style = PaintingStyle.stroke..strokeWidth = sw..strokeCap = StrokeCap.round..color = color;
      canvas.drawArc(rect, math.pi * 0.75, math.pi * 1.5 * t.clamp(0.0, 1.0), false, p);
    }
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.t != t || o.color != color;
}

/// Seven-axis skill radar. Axes without enough data are drawn at the center with a dashed marker.
class RadarChart extends StatelessWidget {
  const RadarChart({super.key, required this.axes, this.other, this.size = 260});
  final List<SkillAxis> axes;
  final List<SkillAxis>? other; // optional second player, drawn in violet
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Skill radar. ${axes.map((a) => '${a.label} ${a.score == null ? 'not rated' : a.score!.toStringAsFixed(0)}').join(', ')}.',
        child: SizedBox(
          height: size,
          width: double.infinity,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeOutCubic,
            builder: (_, t, _) => CustomPaint(painter: _RadarPainter(axes, t, other)),
          ),
        ),
      );
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.axes, this.t, this.other);
  final List<SkillAxis> axes;
  final List<SkillAxis>? other;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final n = axes.length;
    if (n < 3) return;
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - 34;
    Offset at(int i, double f) {
      final a = -math.pi / 2 + 2 * math.pi * i / n;
      return c + Offset(math.cos(a), math.sin(a)) * (r * f);
    }

    final grid = Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = AppColors.outline;
    for (final lvl in [0.25, 0.5, 0.75, 1.0]) {
      final path = Path()..moveTo(at(0, lvl).dx, at(0, lvl).dy);
      for (var i = 1; i < n; i++) {
        path.lineTo(at(i, lvl).dx, at(i, lvl).dy);
      }
      canvas.drawPath(path..close(), grid);
    }
    for (var i = 0; i < n; i++) {
      canvas.drawLine(c, at(i, 1), grid);
    }
    // The 50 ring (an average player) is highlighted.
    final avg = Paint()..style = PaintingStyle.stroke..strokeWidth = 1.2..color = AppColors.textDim.withValues(alpha: 0.5);
    final ap = Path()..moveTo(at(0, 0.5).dx, at(0, 0.5).dy);
    for (var i = 1; i < n; i++) {
      ap.lineTo(at(i, 0.5).dx, at(i, 0.5).dy);
    }
    canvas.drawPath(ap..close(), avg);

    if (other != null && other!.length == n) {
      final op = [for (var i = 0; i < n; i++) at(i, ((other![i].score ?? 0) / 100).clamp(0.02, 1.0) * t)];
      final path = Path()..moveTo(op[0].dx, op[0].dy);
      for (var i = 1; i < n; i++) {
        path.lineTo(op[i].dx, op[i].dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = AppColors.accent2.withValues(alpha: 0.18));
      canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.4..strokeJoin = StrokeJoin.round..color = AppColors.accent2);
    }
    final pts = [for (var i = 0; i < n; i++) at(i, ((axes[i].score ?? 0) / 100).clamp(0.02, 1.0) * t)];
    final poly = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < n; i++) {
      poly.lineTo(pts[i].dx, pts[i].dy);
    }
    poly.close();
    canvas.drawPath(poly, Paint()..color = AppColors.accent.withValues(alpha: 0.22));
    canvas.drawPath(poly, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.4..strokeJoin = StrokeJoin.round..color = AppColors.accent);
    for (var i = 0; i < n; i++) {
      final known = axes[i].score != null;
      canvas.drawCircle(pts[i], known ? 4 : 3, Paint()..color = known ? AppColors.accent : AppColors.textDim);
      final tp = TextPainter(
        text: TextSpan(text: axes[i].label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: known ? AppColors.text : AppColors.textDim)),
        textDirection: TextDirection.ltr,
      )..layout();
      final lp = at(i, 1.0) + (at(i, 1.0) - c) / r * 18;
      tp.paint(canvas, lp - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(_RadarPainter o) => o.t != t || o.axes != axes || o.other != other;
}

/// RP over time (oldest to newest). Touch or drag to read a point.
class RpLineChart extends StatefulWidget {
  const RpLineChart({super.key, required this.points, this.height = 190});
  final List<RpPoint> points; // newest first, as returned
  final double height;

  @override
  State<RpLineChart> createState() => _RpLineChartState();
}

class _RpLineChartState extends State<RpLineChart> {
  int? _sel;

  void _pick(double dx, double w, int n) {
    final i = ((dx / w) * (n - 1)).round().clamp(0, n - 1);
    if (i != _sel) HapticFeedback.selectionClick();
    setState(() => _sel = i);
  }

  @override
  Widget build(BuildContext context) {
    final pts = widget.points.reversed.toList();
    if (pts.length < 2) return const SizedBox.shrink();
    final sel = _sel == null ? null : pts[_sel!];
    final prev = _sel == null || _sel == 0 ? null : pts[_sel! - 1];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        height: 22,
        child: Text(
          sel == null
              ? 'Touch the chart to inspect a game'
              : '${sel.rp} RP${prev == null ? '' : '  (${sel.rp - prev.rp >= 0 ? '+' : ''}${sel.rp - prev.rp})'} · ${sel.rank ?? ''} · ${sel.at.toLocal().month}/${sel.at.toLocal().day} ${sel.at.toLocal().hour.toString().padLeft(2, '0')}:${sel.at.toLocal().minute.toString().padLeft(2, '0')}',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: sel == null ? AppColors.textDim : AppColors.text),
        ),
      ),
      LayoutBuilder(
        builder: (_, c) => GestureDetector(
          onTapDown: (d) => _pick(d.localPosition.dx, c.maxWidth, pts.length),
          onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx, c.maxWidth, pts.length),
          onTapUp: (_) => Future.delayed(const Duration(seconds: 3), () => mounted ? setState(() => _sel = null) : null),
          child: SizedBox(height: widget.height, width: double.infinity, child: CustomPaint(painter: _LinePainter(pts, _sel))),
        ),
      ),
    ]);
  }
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.pts, this.sel);
  final List<RpPoint> pts;
  final int? sel;

  @override
  void paint(Canvas canvas, Size size) {
    final vals = pts.map((e) => e.rp.toDouble()).toList();
    final lo = vals.reduce(math.min), hi = vals.reduce(math.max);
    final pad = math.max(10.0, (hi - lo) * 0.15);
    final mn = lo - pad, mx = hi + pad;
    Offset pt(int i) => Offset(size.width * i / (vals.length - 1), size.height * (1 - (vals[i] - mn) / (mx - mn)));

    final g = Paint()..color = AppColors.outline..strokeWidth = 0.8;
    for (var k = 0; k < 4; k++) {
      final y = size.height * k / 3;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < vals.length; i++) {
      final a = pt(i - 1), b = pt(i), mid = (a.dx + b.dx) / 2;
      path.cubicTo(mid, a.dy, mid, b.dy, b.dx, b.dy);
    }
    final fill = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    canvas.drawPath(fill, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [AppColors.accent.withValues(alpha: 0.30), AppColors.accent.withValues(alpha: 0)]).createShader(Offset.zero & size));
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2.6..strokeCap = StrokeCap.round..color = AppColors.accent);
    for (var i = 0; i < vals.length; i++) {
      final up = i == 0 ? null : vals[i] > vals[i - 1];
      final col = up == null ? AppColors.accent : (up ? AppColors.good : AppColors.bad);
      canvas.drawCircle(pt(i), i == sel ? 6 : 3.4, Paint()..color = i == sel ? Colors.white : col);
    }
    if (sel != null) {
      final p = pt(sel!);
      canvas.drawLine(Offset(p.dx, 0), Offset(p.dx, size.height), Paint()..color = Colors.white24..strokeWidth = 1);
    }
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.sel != sel || o.pts != pts;
}

/// Horizontal comparison bar with a label row above.
class BarRow extends StatelessWidget {
  const BarRow({super.key, required this.label, required this.fraction, required this.valueText, this.color = AppColors.accent, this.caption});
  final String label, valueText;
  final String? caption;
  final double? fraction; // 0..1, null = unknown
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5))),
            Text(valueText, style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: tabular)),
          ]),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (fraction ?? 0).clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (_, v, _) => LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: AppColors.surfaceHi, valueColor: AlwaysStoppedAnimation(fraction == null ? AppColors.outline : color)),
            ),
          ),
          if (caption != null) Padding(padding: const EdgeInsets.only(top: 3), child: Text(caption!, style: const TextStyle(color: AppColors.textDim, fontSize: 11.5))),
        ]),
      );
}

/// Win/loss split bar.
class WinLossBar extends StatelessWidget {
  const WinLossBar({super.key, required this.wins, required this.losses, this.height = 10});
  final int wins, losses;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = wins + losses;
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: total == 0
            ? Container(color: AppColors.surfaceHi)
            : Row(children: [
                Expanded(flex: math.max(wins, 0), child: Container(color: AppColors.good)),
                if (wins > 0 && losses > 0) const SizedBox(width: 2),
                Expanded(flex: math.max(losses, 0), child: Container(color: AppColors.bad)),
              ]),
      ),
    );
  }
}

/// Row of W/L dots for recent results, newest first.
class FormStrip extends StatelessWidget {
  const FormStrip(this.deltas, {super.key, this.max = 10});
  final List<RpDelta> deltas;
  final int max;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final d in deltas.take(max))
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: (d.win ? AppColors.good : AppColors.bad).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(8), border: Border.all(color: (d.win ? AppColors.good : AppColors.bad).withValues(alpha: 0.6))),
            child: Text(d.win ? 'W' : 'L', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900, color: d.win ? AppColors.good : AppColors.bad)),
          ),
      ]);
}
