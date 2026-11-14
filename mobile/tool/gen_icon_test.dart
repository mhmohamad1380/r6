// Generates the Android launcher icons. Run: flutter test tool/gen_icon_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

enum Layer { background, foreground, mono, legacy, preview }

const _cyan = ui.Color(0xFF38BDF8);
const _violet = ui.Color(0xFF818CF8);

void paintIcon(ui.Canvas c, double px, Layer layer) {
  final s = px / 108.0;
  c.save();
  c.scale(s, s);

  if (layer == Layer.background || layer == Layer.legacy || layer == Layer.preview) {
    final rect = const ui.Rect.fromLTWH(0, 0, 108, 108);
    if (layer != Layer.background) {
      c.clipRRect(ui.RRect.fromRectAndRadius(rect, const ui.Radius.circular(24)));
    }
    c.drawRect(rect, ui.Paint()..shader = ui.Gradient.linear(const ui.Offset(0, 0), const ui.Offset(108, 108), const [ui.Color(0xFF0A1020), ui.Color(0xFF1B1A4A)]));
    c.drawCircle(const ui.Offset(86, 92), 52, ui.Paint()..shader = ui.Gradient.radial(const ui.Offset(86, 92), 52, [_cyan.withValues(alpha: 0.30), _cyan.withValues(alpha: 0)]));
    c.drawCircle(const ui.Offset(16, 10), 40, ui.Paint()..shader = ui.Gradient.radial(const ui.Offset(16, 10), 40, [_violet.withValues(alpha: 0.28), _violet.withValues(alpha: 0)]));
  }

  if (layer != Layer.background) {
    final mono = layer == Layer.mono;
    // Legacy and preview have no safe-zone crop, so the mark can be larger there.
    final k = (layer == Layer.legacy || layer == Layer.preview) ? 1.28 : 1.0;
    c.translate(54, 54);
    c.scale(k, k);
    final white = mono ? const ui.Color(0xFFFFFFFF) : const ui.Color(0xFFF1F5FF);
    final ring = ui.Paint()..style = ui.PaintingStyle.stroke..strokeWidth = 4.4..strokeCap = ui.StrokeCap.round..color = white;
    const r = 22.0;
    // Four arcs with gaps at N/E/S/W.
    for (var i = 0; i < 4; i++) {
      final start = -math.pi / 2 + i * math.pi / 2 + 0.34;
      c.drawArc(ui.Rect.fromCircle(center: ui.Offset.zero, radius: r), start, math.pi / 2 - 0.68, false, ring);
    }
    // Ticks pointing in through the gaps.
    final tick = ui.Paint()..style = ui.PaintingStyle.stroke..strokeWidth = 4.4..strokeCap = ui.StrokeCap.round..color = white;
    for (var i = 0; i < 4; i++) {
      final a = -math.pi / 2 + i * math.pi / 2;
      c.drawLine(ui.Offset(math.cos(a), math.sin(a)) * (r - 8), ui.Offset(math.cos(a), math.sin(a)) * (r + 7), tick);
    }
    // Rising performance line.
    final pts = const [ui.Offset(-13, 9), ui.Offset(-4, 1), ui.Offset(2, 6), ui.Offset(13, -10)];
    final path = ui.Path()..moveTo(pts[0].dx, pts[0].dy);
    for (final p in pts.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    final line = ui.Paint()..style = ui.PaintingStyle.stroke..strokeWidth = 5..strokeCap = ui.StrokeCap.round..strokeJoin = ui.StrokeJoin.round;
    line.shader = mono ? null : ui.Gradient.linear(pts.first, pts.last, const [_cyan, ui.Color(0xFFA5B4FC)]);
    if (mono) line.color = white;
    c.drawPath(path, line);
    c.drawCircle(pts.last, 4.4, ui.Paint()..color = mono ? white : const ui.Color(0xFFA5B4FC));
  }
  c.restore();
}

Future<void> write(String path, double px, Layer layer) async {
  final rec = ui.PictureRecorder();
  paintIcon(ui.Canvas(rec), px, layer);
  final img = await rec.endRecording().toImage(px.round(), px.round());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path)..createSync(recursive: true)..writeAsBytesSync(data!.buffer.asUint8List());
}

void main() {
  test('generate launcher icons', () async {
    const res = 'android/app/src/main/res';
    const dens = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
      for (final e in dens.entries) {
        final d = '$res/mipmap-${e.key}';
        await write('$d/ic_launcher_foreground.png', 108 * e.value, Layer.foreground);
        await write('$d/ic_launcher_monochrome.png', 108 * e.value, Layer.mono);
        await write('$d/ic_launcher_background.png', 108 * e.value, Layer.background);
        await write('$d/ic_launcher.png', 48 * e.value, Layer.legacy);
        await write('$d/ic_launcher_round.png', 48 * e.value, Layer.legacy);
      }
      await write('../dist/icon-preview.png', 512, Layer.preview);
    });
    for (final f in ['ic_launcher', 'ic_launcher_round']) {
      File('$res/mipmap-anydpi-v26/$f.xml')
        ..createSync(recursive: true)
        ..writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''');
    }
  });
}
