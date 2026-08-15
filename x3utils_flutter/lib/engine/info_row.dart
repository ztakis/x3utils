/// Presentation primitives shared by every read-only info dialog.
///
/// This is the VIEW vocabulary only — a labelled row, how it masks, how it
/// copies. The rules that decide WHICH rows a thing gets belong to whatever is
/// being described: the backup sidecar has its own set, the file inspector has
/// its own, and neither constrains the other.
library;

/// One labelled fact. [state] is the confidence or qualifier that belongs
/// beside the value rather than inside it; [secret] marks per-unit identity
/// material the view masks until the operator reveals it.
class InfoRow {
  const InfoRow(this.label, this.value, {this.state, this.secret = false});

  final String label;
  final String value;
  final String? state;
  final bool secret;

  /// An absent value is never masked — a row of dots where there is no data
  /// would claim something is hidden.
  bool get hasSecret => secret && value != '—';

  /// Masking replaces content but preserves SHAPE, and never hides [state]: a
  /// masked row still reads `matched`, `defaultKey`, `real`.
  String display({required bool revealed}) {
    final shown = hasSecret && !revealed
        ? value.replaceAll(RegExp(r'[^ ]'), '•')
        : value;
    return state == null ? shown : '$shown ($state)';
  }

  /// One plain-text line for Copy all: the same row, column-aligned.
  String plainLine(int labelWidth) =>
      '${label.padRight(labelWidth)}${display(revealed: true)}';
}

/// A described thing, or the reason it could not be described.
class InfoReport {
  const InfoReport({
    required this.title,
    this.intro,
    this.message,
    this.rows = const <InfoRow>[],
  });

  final String title;
  final String? intro;

  /// Set instead of [rows] when the subject could not be read or understood.
  final String? message;
  final List<InfoRow> rows;
}

/// An absent value reads as an em dash everywhere, never as `null`.
String infoText(Object? value) => value?.toString() ?? '—';

/// Uppercase hex in fixed-width groups, so a long identity string can be read
/// off the screen and compared by eye.
String infoGrouped(Object? value, int groupSize) {
  final raw = infoText(value);
  if (raw == '—') return raw;
  final compact = raw.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  return [
    for (var i = 0; i < compact.length; i += groupSize)
      compact.substring(
        i,
        i + groupSize > compact.length ? compact.length : i + groupSize,
      ),
  ].join(' ');
}
