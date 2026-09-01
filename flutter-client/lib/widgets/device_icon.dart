import 'package:flutter/material.dart';

/// One place that decides how a device is drawn and described.
///
/// ROUND 6: the mobile list drew a phone for every row, so a Windows PC and a
/// Chrome extension both looked like handsets. Shared between the phone and the
/// desktop client on purpose - if the two ever disagreed about what a device
/// looks like, the account screen would contradict itself across platforms.
///
/// The tag comes from `POST /api/devices/register` (`android`, `windows`,
/// `chrome`, ...) and is matched loosely by design: rows created by older
/// builds carry values this version never sends, and an unrecognised tag must
/// fall back to something neutral rather than assert something false.
IconData iconForDevicePlatform(String? platform) {
  final String tag = (platform ?? '').toLowerCase();
  if (tag.contains('android')) return Icons.smartphone_rounded;
  if (tag.contains('iphone') || tag.contains('ios')) {
    return Icons.smartphone_rounded;
  }
  if (tag.contains('ipad') || tag.contains('tablet')) {
    return Icons.tablet_android_rounded;
  }
  if (tag.contains('win')) return Icons.desktop_windows_rounded;
  if (tag.contains('mac') || tag.contains('darwin')) {
    return Icons.laptop_mac_rounded;
  }
  if (tag.contains('linux')) return Icons.computer_rounded;
  if (tag.contains('chrome') ||
      tag.contains('firefox') ||
      tag.contains('edge') ||
      tag.contains('extension') ||
      tag.contains('browser')) {
    return Icons.extension_rounded;
  }
  return Icons.devices_other_rounded;
}

/// Human words for the same tag. Returns an empty string when there is nothing
/// honest to say, so callers can simply skip the line.
String describeDevicePlatform(String? platform, {required bool ru}) {
  final String raw = (platform ?? '').trim();
  final String tag = raw.toLowerCase();
  if (tag.isEmpty || tag == 'unknown') return '';
  if (tag.contains('android')) return 'Android';
  if (tag.contains('win')) return 'Windows';
  if (tag.contains('iphone') || tag.contains('ios')) return 'iOS';
  if (tag.contains('mac') || tag.contains('darwin')) return 'macOS';
  if (tag.contains('linux')) return 'Linux';
  if (tag.contains('chrome')) {
    return ru ? 'Chrome \u00b7 \u0440\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u0438\u0435' : 'Chrome extension';
  }
  if (tag.contains('firefox')) {
    return ru ? 'Firefox \u00b7 \u0440\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u0438\u0435' : 'Firefox extension';
  }
  if (tag.contains('edge')) {
    return ru ? 'Edge \u00b7 \u0440\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u0438\u0435' : 'Edge extension';
  }
  if (tag.contains('extension') || tag.contains('browser')) {
    return ru ? '\u0420\u0430\u0441\u0448\u0438\u0440\u0435\u043d\u0438\u0435 \u0431\u0440\u0430\u0443\u0437\u0435\u0440\u0430' : 'Browser extension';
  }
  // Unrecognised but non-empty: show what the server said rather than invent a
  // label for it.
  return raw;
}
