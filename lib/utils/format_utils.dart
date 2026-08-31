import 'package:easy_localization/easy_localization.dart';

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final value = unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$value ${units[unit]}';
}

String? formatDownloadSize(int? receivedBytes, int? totalBytes) {
  if (receivedBytes == null) return null;
  if (totalBytes != null && totalBytes > 0) {
    return '${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}';
  }
  return formatBytes(receivedBytes);
}

/// Resolves a generated-form option label.
///
/// A label is normally a translation key. A `unit:count` pair ("hour:4",
/// "day:2") is instead resolved with the pluralized unit string, so an option
/// list can carry counted durations without a translation key per value.
String formOptLabel(String label) {
  final separator = label.indexOf(':');
  if (separator > 0) {
    final count = int.tryParse(label.substring(separator + 1));
    if (count != null) return plural(label.substring(0, separator), count);
  }
  return tr(label);
}
