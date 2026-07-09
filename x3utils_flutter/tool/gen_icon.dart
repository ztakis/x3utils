// Renders the x3utils app icon (the in-app logo: teal→magenta rounded square
// with a lightning bolt) to windows/runner/resources/app_icon.ico + icon.png.
// Run:  dart run tool/gen_icon.dart
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const size = 256;
  const pad = size * 0.06;
  const left = pad, top = pad, right = size - pad, bottom = size - pad;
  const w = right - left, h = bottom - top;
  const r = w * 0.24; // corner radius

  // brand teal -> hot magenta (matches AppColors.brand / AppColors.pop)
  const c0 = [0x16, 0xE0, 0xC4];
  const c1 = [0xFF, 0x2E, 0x88];

  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0)); // transparent

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (!_inRoundRect(x + 0.5, y + 0.5, left, top, right, bottom, r)) continue;
      final t = (((x - left) + (y - top)) / (w + h)).clamp(0.0, 1.0);
      image.setPixelRgba(
        x,
        y,
        (c0[0] + (c1[0] - c0[0]) * t).round(),
        (c0[1] + (c1[1] - c0[1]) * t).round(),
        (c0[2] + (c1[2] - c0[2]) * t).round(),
        255,
      );
    }
  }

  // lightning bolt (dark), normalized in the padded box then scaled
  const bolt = <List<double>>[
    [0.55, 0.10],
    [0.30, 0.54],
    [0.47, 0.54],
    [0.41, 0.90],
    [0.70, 0.44],
    [0.53, 0.44],
    [0.61, 0.10],
  ];
  final verts = [
    for (final p in bolt) img.Point(left + p[0] * w, top + p[1] * h),
  ];
  img.fillPolygon(image,
      vertices: verts, color: img.ColorRgba8(0x04, 0x12, 0x0F, 255));

  File('icon.png').writeAsBytesSync(img.encodePng(image));
  Directory('windows/runner/resources').createSync(recursive: true);
  File('windows/runner/resources/app_icon.ico')
      .writeAsBytesSync(img.encodeIco(image));
  stdout.writeln('wrote icon.png + windows/runner/resources/app_icon.ico');
}

bool _inRoundRect(
    double x, double y, double l, double t, double rt, double b, double r) {
  if (x < l || x > rt || y < t || y > b) return false;
  final inCornerX = x < l + r || x > rt - r;
  final inCornerY = y < t + r || y > b - r;
  if (inCornerX && inCornerY) {
    final cx = x < (l + rt) / 2 ? l + r : rt - r;
    final cy = y < (t + b) / 2 ? t + r : b - r;
    final dx = x - cx, dy = y - cy;
    return dx * dx + dy * dy <= r * r;
  }
  return true;
}
