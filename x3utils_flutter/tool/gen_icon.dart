// Renders the x3utils app icon (the in-app logo: teal→magenta rounded square
// with a lightning bolt) to icon.png, Windows .ico, macOS AppIcon assets, and
// Android launcher mipmaps.
// Run:  dart run tool/gen_icon.dart
import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final master = _renderIcon(1024);
  final icon256 = img.copyResize(
    master,
    width: 256,
    height: 256,
    interpolation: img.Interpolation.average,
  );

  File('icon.png').writeAsBytesSync(img.encodePng(icon256));

  Directory('windows/runner/resources').createSync(recursive: true);
  File(
    'windows/runner/resources/app_icon.ico',
  ).writeAsBytesSync(img.encodeIco(icon256));

  final macIconDir = Directory(
    'macos/Runner/Assets.xcassets/AppIcon.appiconset',
  );
  macIconDir.createSync(recursive: true);
  for (final size in <int>[16, 32, 64, 128, 256, 512, 1024]) {
    final icon = size == 1024
        ? master
        : img.copyResize(
            master,
            width: size,
            height: size,
            interpolation: img.Interpolation.average,
          );
    File(
      '${macIconDir.path}/app_icon_$size.png',
    ).writeAsBytesSync(img.encodePng(icon));
  }

  const androidSizes = <String, int>{
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };
  for (final entry in androidSizes.entries) {
    final dir = Directory('android/app/src/main/res/${entry.key}');
    dir.createSync(recursive: true);
    final icon = img.copyResize(
      master,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.average,
    );
    File('${dir.path}/ic_launcher.png').writeAsBytesSync(img.encodePng(icon));
  }

  Directory('web/icons').createSync(recursive: true);
  File('web/favicon.png').writeAsBytesSync(img.encodePng(
    img.copyResize(master, width: 48, height: 48,
        interpolation: img.Interpolation.average),
  ));
  for (final size in <int>[192, 512]) {
    final icon = img.copyResize(master, width: size, height: size,
        interpolation: img.Interpolation.average);
    final png = img.encodePng(icon);
    File('web/icons/Icon-$size.png').writeAsBytesSync(png);
    File('web/icons/Icon-maskable-$size.png').writeAsBytesSync(png);
  }

  stdout.writeln(
    'wrote icon.png + Windows, macOS, Android, and web assets',
  );
}

img.Image _renderIcon(int size) {
  final pad = size * 0.06;
  final left = pad, top = pad, right = size - pad, bottom = size - pad;
  final w = right - left, h = bottom - top;
  final r = w * 0.24; // corner radius

  // brand teal -> hot magenta (matches AppColors.brand / AppColors.pop)
  const c0 = [0x16, 0xE0, 0xC4];
  const c1 = [0xFF, 0x2E, 0x88];

  final image = img.Image(width: size, height: size, numChannels: 4);
  img.fill(image, color: img.ColorRgba8(0, 0, 0, 0)); // transparent

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      if (!_inRoundRect(x + 0.5, y + 0.5, left, top, right, bottom, r)) {
        continue;
      }
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
  img.fillPolygon(
    image,
    vertices: verts,
    color: img.ColorRgba8(0x04, 0x12, 0x0F, 255),
  );

  return image;
}

bool _inRoundRect(
  double x,
  double y,
  double l,
  double t,
  double rt,
  double b,
  double r,
) {
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
