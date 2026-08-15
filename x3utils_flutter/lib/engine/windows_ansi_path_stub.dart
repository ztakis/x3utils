class WindowsAnsiPathResult {
  const WindowsAnsiPathResult({
    required this.originalPath,
    required this.codePage,
    required this.exact,
    this.roundTrippedPath,
  });

  final String originalPath;
  final int codePage;
  final bool exact;
  final String? roundTrippedPath;

  int? get firstDifferenceIndex => null;
  int? get offendingCodePoint => null;
  String? get offendingCharacter => null;
}

/// Compile-time browser stand-in. Firmware never calls this because Web is not
/// Windows and no browser path is handed to OpenOCD.
class WindowsAnsiPath {
  static int get activeCodePage =>
      throw UnsupportedError('Windows ACP exists only on Windows.');

  static WindowsAnsiPathResult check(String path, {int? codePage}) =>
      throw UnsupportedError('Windows ACP validation exists only on Windows.');
}
