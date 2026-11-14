import 'package:flutter/material.dart';

import '../../core/theme.dart';

class TrendChart extends StatelessWidget {
  const TrendChart(this.values, {super.key});
  final List<double> values;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 140,
        width: double.infinity,
        child: CustomPaint(painter: _TrendPainter(values)),
      );
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.v);
  final List<double> v;

  @override
  void paint(Canvas canvas, Size size) {
    if (v.length < 2) return;
    final lo = v.reduce((a, b) => a < b ? a : b) - 5;
    final hi = v.reduce((a, b) => a > b ? a : b) + 5;
    Offset pt(int i) => Offset(
          size.width * i / (v.length - 1),
          size.height * (1 - (v[i] - lo) / (hi - lo)),
        );
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < v.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = AppColors.accent.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = AppColors.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.v != v;
}
