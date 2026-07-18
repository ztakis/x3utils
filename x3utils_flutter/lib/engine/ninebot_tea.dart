import 'dart:io';
import 'dart:typed_data';

/// Dart port of ScooterHacking's NinebotTEA (`ninebottea/ninebottea.py`):
/// https://github.com/scooterhacking/NinebotTEA
///
/// TEA (Tiny Encryption Algorithm), 32 rounds, chained CBC-style over 8-byte
/// blocks, with the 128-bit key nudged (`byte + index`) after every 1 KB. Used
/// for Ninebot / Xiaomi third-generation scooter firmware. A 4-byte swapped,
/// inverted 32-bit checksum is padded onto the plaintext before encryption and
/// verified on decryption.
///
/// Faithful to the reference, with one deliberate representation change: the
/// Python assembles a full 64-bit block and shifts it (`block >> 32`), which
/// would collide with the sign bit of Dart's signed 64-bit `int`. This port
/// keeps every value as an unsigned 32-bit word (`0 .. 0xFFFFFFFF`) so all
/// shifts stay logical and the arithmetic is exact. It is therefore correct on
/// native/desktop ints and is NOT web-safe (web `int` is a 53-bit double).
class NinebotTea {
  /// Default firmware key — the same 16 bytes as the SHU-compat signature
  /// ([CompatPatch.signature] in firmware.dart).
  static final Uint8List defaultKey = Uint8List.fromList(const [
    0xFE, 0x80, 0x1C, 0xB2, 0xD1, 0xEF, 0x41, 0xA6, //
    0xA4, 0x17, 0x31, 0xF5, 0xA0, 0x68, 0x24, 0xF0,
  ]);

  static const int _delta = 0x9E3779B9;
  static const int _numRounds = 32;
  static const int _mask = 0xFFFFFFFF;
  static const int _keyRefreshBytes = 1024;

  final List<int> _key; // 4 little-endian 32-bit words
  final int _ivLo;
  final int _ivHi;

  /// [key] must be 16 bytes (defaults to [defaultKey]); [iv] must be 8 bytes
  /// (defaults to all zeros, as in the reference).
  factory NinebotTea({List<int>? key, List<int>? iv}) {
    final k = key ?? defaultKey;
    final v = iv ?? Uint8List(8);
    if (k.length != 16) {
      throw ArgumentError('Key must be exactly 16 bytes, got ${k.length}.');
    }
    if (v.length != 8) {
      throw ArgumentError('IV must be exactly 8 bytes, got ${v.length}.');
    }
    return NinebotTea._(_wordsFromKey(k), _readWord(v, 0), _readWord(v, 4));
  }

  const NinebotTea._(this._key, this._ivLo, this._ivHi);

  /// Pad + checksum, then encrypt. Returns a fresh buffer (multiple of 8).
  Uint8List encrypt(List<int> plaintext) {
    final data = _putChecksumAndPad(plaintext);
    final out = Uint8List(data.length);
    var key = _key;
    var ivLo = _ivLo, ivHi = _ivHi;
    var processed = 0;
    for (var i = 0; i < data.length; i += 8) {
      if (processed == _keyRefreshBytes) {
        key = _updateKey(key);
        processed = 0;
      }
      final y = _readWord(data, i) ^ ivLo;
      final z = _readWord(data, i + 4) ^ ivHi;
      final (ey, ez) = _encryptBlock(y, z, key);
      _putWord(out, i, ey);
      _putWord(out, i + 4, ez);
      ivLo = ey;
      ivHi = ez;
      processed += 8;
    }
    return out;
  }

  /// Decrypt, then verify + strip the trailing checksum. Throws
  /// [FormatException] if the checksum does not match.
  Uint8List decrypt(List<int> ciphertext) {
    // Reference rounds each block up to 8 bytes on output; mirror that so a
    // truncated final block cannot overflow the buffer.
    final out = Uint8List(((ciphertext.length + 7) >> 3) << 3);
    var key = _key;
    var ivLo = _ivLo, ivHi = _ivHi;
    var processed = 0;
    for (var i = 0; i < ciphertext.length; i += 8) {
      if (processed == _keyRefreshBytes) {
        key = _updateKey(key);
        processed = 0;
      }
      final c0 = _readWord(ciphertext, i);
      final c1 = _readWord(ciphertext, i + 4);
      final (dy, dz) = _decryptBlock(c0, c1, key);
      _putWord(out, i, dy ^ ivLo);
      _putWord(out, i + 4, dz ^ ivHi);
      ivLo = c0;
      ivHi = c1;
      processed += 8;
    }
    return _verifyAndUnpad(out);
  }

  // ── Block cipher (pure; take the live key so callers can rotate it) ────────

  static (int, int) _encryptBlock(int y, int z, List<int> key) {
    var sum = 0;
    for (var i = 0; i < _numRounds; i++) {
      sum = (sum + _delta) & _mask;
      y = (y + ((((z << 4) + key[0]) ^ (z + sum) ^ ((z >> 5) + key[1])))) & _mask;
      z = (z + ((((y << 4) + key[2]) ^ (y + sum) ^ ((y >> 5) + key[3])))) & _mask;
    }
    return (y, z);
  }

  static (int, int) _decryptBlock(int y, int z, List<int> key) {
    // Python starts at `delta * numRounds` unmasked; masking here is identical
    // because every use is reduced mod 2^32 by the trailing `& _mask`.
    var sum = (_delta * _numRounds) & _mask;
    for (var i = 0; i < _numRounds; i++) {
      z = (z - ((((y << 4) + key[2]) ^ (y + sum) ^ ((y >> 5) + key[3])))) & _mask;
      y = (y - ((((z << 4) + key[0]) ^ (z + sum) ^ ((z >> 5) + key[1])))) & _mask;
      sum = (sum - _delta) & _mask;
    }
    return (y, z);
  }

  // ── Checksum / padding ─────────────────────────────────────────────────────

  /// Pad to a multiple of 4, guarantee the pre-checksum length is NOT a
  /// multiple of 8 (so the 4-byte checksum lands the total on an 8-byte
  /// boundary), then append the checksum.
  Uint8List _putChecksumAndPad(List<int> data) {
    final out = BytesBuilder();
    out.add(data);
    final padNeeded = (4 - data.length % 4) % 4;
    if (padNeeded > 0) out.add(Uint8List(padNeeded));
    if (out.length % 8 == 0) out.add(Uint8List(4));
    final body = out.toBytes();
    out.add(_word32le(_checksum(body)));
    return out.toBytes();
  }

  Uint8List _verifyAndUnpad(List<int> data) {
    if (data.length < 4) {
      throw const FormatException('Data too short to contain a valid checksum.');
    }
    final provided = _readWord(data, data.length - 4);
    final body = Uint8List.fromList(data.sublist(0, data.length - 4));
    if (_checksum(body) != provided) {
      throw const FormatException('Checksum does not match.');
    }
    return body;
  }

  /// Sum of little-endian 32-bit words (mod 2^32), 16-bit halves swapped, then
  /// bitwise-inverted.
  static int _checksum(List<int> data) {
    var sum = 0;
    for (var i = 0; i < data.length; i += 4) {
      sum = (sum + _readWord(data, i)) & _mask;
    }
    sum = ((sum >> 16) & 0xFFFF) | ((sum & 0xFFFF) << 16);
    return (sum ^ _mask) & _mask;
  }

  // ── Key schedule ───────────────────────────────────────────────────────────

  static List<int> _wordsFromKey(List<int> key) =>
      [for (var i = 0; i < 16; i += 4) _readWord(key, i)];

  /// After each 1 KB, every key byte becomes `(byte + itsIndex) & 0xFF`.
  static List<int> _updateKey(List<int> key) {
    final bytes = Uint8List(16);
    for (var w = 0; w < 4; w++) {
      _putWord(bytes, w * 4, key[w]);
    }
    for (var i = 0; i < 16; i++) {
      bytes[i] = (bytes[i] + i) & 0xFF;
    }
    return _wordsFromKey(bytes);
  }

  // ── Little-endian word I/O (partial-read safe, like Python slicing) ─────────

  static int _readWord(List<int> b, int off) {
    var v = 0;
    for (var k = 0; k < 4 && off + k < b.length; k++) {
      v |= b[off + k] << (8 * k);
    }
    return v;
  }

  static void _putWord(Uint8List out, int off, int w) {
    out[off] = w & 0xFF;
    out[off + 1] = (w >> 8) & 0xFF;
    out[off + 2] = (w >> 16) & 0xFF;
    out[off + 3] = (w >> 24) & 0xFF;
  }

  static Uint8List _word32le(int w) => Uint8List.fromList([
        w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF, //
      ]);

  // ── Convenience helpers (mirror ninebottea/__main__.py) ────────────────────

  /// Parse a 32-hex-char (16-byte) key. Spaces are ignored.
  static Uint8List keyFromHex(String hex) {
    final clean = hex.trim().replaceAll(' ', '');
    if (clean.length != 32) {
      throw ArgumentError('Key must be 16 bytes (32 hex chars), got ${clean.length} chars.');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// Encrypt [inPath] → [outPath]. [key] defaults to [defaultKey].
  static void encryptFile(String inPath, String outPath, {List<int>? key}) {
    final data = File(inPath).readAsBytesSync();
    File(outPath).writeAsBytesSync(NinebotTea(key: key).encrypt(data));
  }

  /// Decrypt [inPath] → [outPath]. Throws [FormatException] on a bad checksum.
  static void decryptFile(String inPath, String outPath, {List<int>? key}) {
    final data = File(inPath).readAsBytesSync();
    File(outPath).writeAsBytesSync(NinebotTea(key: key).decrypt(data));
  }
}
