/// Presentation helpers. Pure functions, no dependencies, easy to unit test.
library;

/// Turns an ISO 3166-1 alpha-2 code into a flag emoji ("DE" -> German flag).
///
/// The flag is derived from whatever the node actually reports, so a node that
/// is not really in Germany never shows a German flag.
String countryFlag(String countryCode) {
  final String code = countryCode.trim().toUpperCase();
  if (code.length != 2) return '\u{1F3F4}';
  const int base = 0x1F1E6; // REGIONAL INDICATOR SYMBOL LETTER A
  const int letterA = 0x41;
  final int first = code.codeUnitAt(0);
  final int second = code.codeUnitAt(1);
  if (first < letterA || first > letterA + 25 || second < letterA || second > letterA + 25) {
    return '\u{1F3F4}';
  }
  return String.fromCharCodes(<int>[base + (first - letterA), base + (second - letterA)]);
}

/// `HH:MM:SS` once past an hour, otherwise `MM:SS`.
String formatDuration(Duration duration) {
  final Duration d = duration.isNegative ? Duration.zero : duration;
  final String two = d.inHours > 0 ? d.inHours.toString().padLeft(2, '0') : '';
  final String minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final String seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return two.isEmpty ? '$minutes:$seconds' : '$two:$minutes:$seconds';
}

String formatSeconds(int? seconds) =>
    seconds == null ? '--:--' : formatDuration(Duration(seconds: seconds));

/// Byte counters come straight from WireGuard, so they can be large.
String formatBytes(int? bytes) {
  if (bytes == null) return '0 B';
  final int value = bytes < 0 ? 0 : bytes;
  if (value < 1024) return '$value B';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double size = value / 1024;
  int unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final String text = size >= 100 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String formatPing(int? milliseconds) =>
    milliseconds == null ? '--' : '$milliseconds ms';

String formatPercent(double? value) =>
    value == null ? '--' : '${value.clamp(0, 100).toStringAsFixed(0)}%';

/// Compact local timestamp: `2026-08-19 16:45`.
String formatDateTime(DateTime? value) {
  if (value == null) return '--';
  final DateTime local = value.toLocal();
  final String month = local.month.toString().padLeft(2, '0');
  final String day = local.day.toString().padLeft(2, '0');
  final String hour = local.hour.toString().padLeft(2, '0');
  final String minute = local.minute.toString().padLeft(2, '0');
  return '${local.year}-$month-$day $hour:$minute';
}

/// "3m ago" style relative label, used for heartbeat / last-seen fields.
String formatRelative(DateTime? value) {
  if (value == null) return 'never';
  final Duration delta = DateTime.now().difference(value);
  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 60) return '${delta.inSeconds}s ago';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  return '${delta.inDays}d ago';
}

/// Human-readable node uptime.
String formatUptime(int? seconds) {
  if (seconds == null) return '--';
  final Duration d = Duration(seconds: seconds);
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours.remainder(24)}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  return '${d.inMinutes}m';
}
