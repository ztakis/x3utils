// Derived from swdart, MIT licensed. See third_party/swdart/LICENSE.
import 'dart:typed_data';

String hex(int value, [int width = 8]) =>
    '0x${(value & 0xFFFFFFFF).toRadixString(16).toUpperCase().padLeft(width, '0')}';

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

int u32le(Uint8List bytes, int offset) =>
    (bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24)) &
    0xFFFFFFFF;

List<int> u32(int value) => [
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
];

List<int> u16(int value) => [value & 0xff, (value >> 8) & 0xff];

class SwdException implements Exception {
  SwdException(this.message);

  final String message;

  @override
  String toString() => message;
}
