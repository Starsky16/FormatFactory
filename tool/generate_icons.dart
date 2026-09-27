import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 应用图标生成器（Flutter 渲染，程序化生成，无外部图片工具依赖）。
///
/// 运行：flutter test tool/generate_icons.dart
/// 设计：浅灰底 + "带烟囱的厂房 + 厂房内的换向箭头"。
/// 厂房＝所有处理都在本地这台"厂"里完成（不联网、不上传）；
/// 厂房内的 ⇄＝格式转换 / 音乐脱壳 / 双流合并这几件事都在厂内完成。
/// 屋顶板与烟囱画成实心色块（不靠线宽留白），墙体用 6.5 单位描边，箭头实心。
/// 图形按 108dp 画布坐标设计：自适应前景层按原始比例（外缘落在安全区内），
/// legacy 圆角图不被系统遮罩裁切，再放大 [_legacyScale] 倍铺得更满。
/// 输出会直接覆盖 android/app/src/main/res 下的 mipmap 图标资源。
/// 已从 test/ 移出，普通 `flutter test` 不会执行它。
void main() async {
  await generateIcons();
}

// 中性灰阶：不绑定固定彩色，方便以后适配 Android 13+ 主题图标（莫奈取色）
const int _cInk = 0xFF1E2A38; // 厂房轮廓与内部箭头
const int _cBg = 0xFFF1F3F7; // 自适应背景层 / legacy 圆角底

/// legacy 圆角图可以铺满画布，比自适应前景层再放大一点
const double _legacyScale = 1.25;

const List<(String, int)> _dpiLegacy = [
  ('mipmap-mdpi', 48),
  ('mipmap-hdpi', 72),
  ('mipmap-xhdpi', 96),
  ('mipmap-xxhdpi', 144),
  ('mipmap-xxxhdpi', 192),
];

const List<(String, int)> _dpiForeground = [
  ('mipmap-mdpi', 108),
  ('mipmap-hdpi', 162),
  ('mipmap-xhdpi', 216),
  ('mipmap-xxhdpi', 324),
  ('mipmap-xxxhdpi', 432),
];

Future<void> generateIcons() async {
  final root = Directory('android/app/src/main/res');
  for (final (dir, size) in _dpiLegacy) {
    final img = await _render(size, legacyStyle: true);
    await _writePng(
      File('${root.path}/$dir/ic_launcher.png'),
      img,
    );
  }
  for (final (dir, size) in _dpiForeground) {
    final img = await _render(size, legacyStyle: false);
    await _writePng(
      File('${root.path}/$dir/ic_launcher_foreground.png'),
      img,
    );
  }

  // 自适应图标资源（values 颜色 + anydpi-v26 xml）
  final colors = File('${root.path}/values/colors.xml');
  await colors.writeAsString('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">${'#'}${_cBg.toRadixString(16).padLeft(8, '0').substring(2)}</color>
</resources>
''');
  final anydpi = Directory('${root.path}/mipmap-anydpi-v26');
  if (!anydpi.existsSync()) await anydpi.create(recursive: true);
  await File('${anydpi.path}/ic_launcher.xml').writeAsString('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
  // ignore: avoid_print
  print('图标已生成到 $root');
}

Future<ui.Image> _render(int size, {required bool legacyStyle}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final s = size.toDouble();

  if (legacyStyle) {
    // 圆角浅灰底（legacy 图标不会被系统遮罩裁切）
    canvas.clipRRect(ui.RRect.fromRectAndRadius(
      ui.Rect.fromLTWH(0, 0, s, s),
      ui.Radius.circular(size * 0.20),
    ));
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, s, s),
      ui.Paint()..color = const ui.Color(_cBg),
    );
    _drawFactory(canvas, s, _legacyScale);
  } else {
    // 自适应前景层：透明底，图形按 108dp 原始比例
    _drawFactory(canvas, s, 1.0);
  }

  return recorder.endRecording().toImage(size, size);
}

/// 在 [s]×[s] 的画布上按 108dp 坐标绘制厂房，[k] 为额外缩放系数。
///
/// 外缘范围 x 26.75~81.25、y 25~80.75（含 6.5 单位线宽），最远点在底部两角
/// （距画面中心约 34），落在启动器圆形遮罩的安全区内。
void _drawFactory(ui.Canvas canvas, double s, double k) {
  canvas.save();
  canvas.translate(s / 2, s / 2);
  canvas.scale(s / 108 * k);
  canvas.translate(-54, -54);

  const strokeW = 6.5;

  // 两根烟囱，实心：工厂最直白的剪影特征。必须实心——描边线宽会把管腔堵死，
  // 看起来像提手。烟囱直接落在屋顶（墙体上边线）上，一高一矮，避免被读成提手。
  final chimney = ui.Paint()..color = const ui.Color(_cInk);
  canvas.drawRect(const ui.Rect.fromLTRB(40, 25, 47.5, 48), chimney); // 左烟囱（高）
  canvas.drawRect(const ui.Rect.fromLTRB(60.5, 31, 68, 48), chimney); // 右烟囱（矮）

  // 厂房墙体：平顶矩形厂房（线宽 6.5，画在路径中心线上）
  final outline = ui.Path()
    ..moveTo(30, 45)
    ..lineTo(78, 45)
    ..lineTo(78, 70.5)
    ..arcToPoint(const ui.Offset(71, 77.5),
        radius: const ui.Radius.circular(7), clockwise: true)
    ..lineTo(37, 77.5)
    ..arcToPoint(const ui.Offset(30, 70.5),
        radius: const ui.Radius.circular(7), clockwise: true)
    ..close();

  canvas.drawPath(
    outline,
    ui.Paint()
      ..color = const ui.Color(_cInk)
      ..style = ui.PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeJoin = ui.StrokeJoin.miter
      ..strokeCap = ui.StrokeCap.butt,
  );

  // 厂房内的实心 ⇄：上排向右、下排向左
  const arrowW = 6.5;
  const headHalf = 4.75;
  const yTop = 54.75;
  const yBottom = 67.25;

  final line = ui.Paint()
    ..color = const ui.Color(_cInk)
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = arrowW
    ..strokeCap = ui.StrokeCap.butt;
  final solid = ui.Paint()..color = const ui.Color(_cInk);

  canvas.drawLine(const ui.Offset(39, yTop), const ui.Offset(58.5, yTop), line);
  canvas.drawPath(
    ui.Path()
      ..moveTo(69, yTop)
      ..lineTo(58.5, yTop - headHalf)
      ..lineTo(58.5, yTop + headHalf)
      ..close(),
    solid,
  );

  canvas.drawLine(
      const ui.Offset(69, yBottom), const ui.Offset(49.5, yBottom), line);
  canvas.drawPath(
    ui.Path()
      ..moveTo(39, yBottom)
      ..lineTo(49.5, yBottom - headHalf)
      ..lineTo(49.5, yBottom + headHalf)
      ..close(),
    solid,
  );

  canvas.restore();
}

Future<void> _writePng(File file, ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final bytes = data!.buffer.asUint8List();
  file.writeAsBytesSync(bytes);
}
