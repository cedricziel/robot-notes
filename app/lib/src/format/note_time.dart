/// Timestamp formatting shared by the notes list, search results, and the
/// note view, so every screen describes "when" the same way.
library;

/// Formats [dt] in the device's local time zone as `YYYY-MM-DD HH:MM`.
String formatNoteTimestamp(DateTime dt) {
  final t = dt.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)} '
      '${_two(t.hour)}:${_two(t.minute)}';
}

/// Formats [dt] in the device's local time zone as `YYYY-MM-DD`.
String formatNoteDate(DateTime dt) {
  final t = dt.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

/// Formats [dt] in the device's local time zone as `HH:MM`.
String formatClockTime(DateTime dt) {
  final t = dt.toLocal();
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// Formats [dt] relative to [now] (defaulting to the current instant) as
/// "just now" / "N minute(s) ago" / "N hour(s) ago" / "N day(s) ago", or
/// falls back to [formatNoteTimestamp] beyond a week — an absolute date is
/// more useful than "N days ago" once the gap gets that wide.
///
/// A negative difference ([dt] ahead of [now], i.e. server/client clock
/// skew) also falls back to the absolute form rather than reading as
/// "just now" no matter how far in the future it is.
String formatRelativeNoteTime(DateTime dt, {DateTime? now}) {
  final reference = now ?? DateTime.now();
  final diff = reference.difference(dt);
  if (diff.isNegative || diff.inDays >= 7) return formatNoteTimestamp(dt);
  if (diff.inDays >= 1) return _plural(diff.inDays, 'day');
  if (diff.inHours >= 1) return _plural(diff.inHours, 'hour');
  if (diff.inMinutes >= 1) return _plural(diff.inMinutes, 'minute');
  return 'just now';
}

String _plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} ago';

String _two(int n) => n.toString().padLeft(2, '0');
