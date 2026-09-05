import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/device_limit.dart';
import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../theme/tokens.dart';
import '../i18n/desktop_strings.dart';
import '../theme/desktop_theme.dart';

/// "Device limit reached (5 / 5)" for the Windows client.
///
/// The phone has had this since round 28; the PC only had the dead end. When
/// `POST /api/devices/register` is refused with a 409, the desktop connect flow
/// used to report "Could not register this PC as a device" and stop, so the
/// only way out was to find another machine and sign a device out there. The
/// server attaches the devices holding the slots to that 409, which is exactly
/// the list this dialog renders.
///
/// Deliberately not a reuse of the phone's `showDeviceLimitDialog`: that one is
/// a Material `AlertDialog` on the mobile palette, and it cannot show which
/// node a device is connected through - the desktop requirement asks for it, and
/// only `GET /api/devices` carries `connectedNode`.
///
/// Returns true when a slot was freed and this PC re-registered, so the caller
/// can go straight on to connecting.
Future<bool> showDeviceLimitSheet({
  required BuildContext context,
  required DesktopStrings strings,
  required DeviceLimitDetails details,
  required ApiClient api,
  required Future<void> Function(String deviceId) onRelease,
}) async {
  final bool? freed = await showDialog<bool>(
    context: context,
    // Dismissible: being trapped in a modal is worse than being at the limit.
    // The dialog itself refuses to close only while a revoke is in flight.
    barrierDismissible: true,
    barrierColor: Colors.black.withOpacity(0.55),
    builder: (BuildContext ctx) => _DeviceLimitSheet(
      strings: strings,
      details: details,
      api: api,
      onRelease: onRelease,
    ),
  );
  return freed ?? false;
}

/// One row of the picker, merged from the 409 body and `GET /api/devices`.
class _SlotRow {
  const _SlotRow({
    required this.id,
    required this.name,
    this.platform,
    this.lastSeen,
    this.connected = false,
    this.nodeName,
    this.isCurrent = false,
  });

  /// From the error body: always available, even before the list request
  /// answers, and the only source during sign-in when there is no
  /// device-scoped token yet.
  factory _SlotRow.fromLimit(DeviceLimitSlot slot, bool ru) => _SlotRow(
        id: slot.id,
        name: slot.label(ru),
        platform: slot.platform.isEmpty ? null : slot.platform,
        lastSeen: slot.lastSeen,
        connected: slot.connected,
        nodeName: slot.connectedNode?.label.isNotEmpty == true ? slot.connectedNode!.label : slot.connectedNode?.name,
      );

  /// From `GET /api/devices`: the same row plus the node it egresses through.
  factory _SlotRow.fromDevice(DeviceInfo device, bool ru) => _SlotRow(
        id: device.id,
        name: device.deviceName.isNotEmpty
            ? device.deviceName
            : (device.platform ?? (ru ? 'Устройство' : 'Device')),
        platform: device.platform,
        lastSeen: device.lastSeen,
        connected: device.connected,
        nodeName: device.connectedNodeName,
        isCurrent: device.isCurrent,
      );

  final String id;
  final String name;
  final String? platform;
  final DateTime? lastSeen;
  final bool connected;
  final String? nodeName;
  final bool isCurrent;
}

class _DeviceLimitSheet extends StatefulWidget {
  const _DeviceLimitSheet({
    required this.strings,
    required this.details,
    required this.api,
    required this.onRelease,
  });

  final DesktopStrings strings;
  final DeviceLimitDetails details;
  final ApiClient api;
  final Future<void> Function(String deviceId) onRelease;

  @override
  State<_DeviceLimitSheet> createState() => _DeviceLimitSheetState();
}

class _DeviceLimitSheetState extends State<_DeviceLimitSheet> {
  late List<_SlotRow> _rows;
  bool _loading = true;
  bool _stale = false;
  String? _error;
  String? _busyId;

  bool get _ru => widget.strings.isRussian;

  @override
  void initState() {
    super.initState();
    // Start with what the 409 already gave us, so the list is never an empty
    // box while the enrichment request is in flight.
    _rows = widget.details.devices
        .map((DeviceLimitSlot slot) => _SlotRow.fromLimit(slot, _ru))
        .toList();
    unawaited(_enrich());
  }

  /// Adds what only the device list knows: which node each tunnel runs through.
  ///
  /// A failure here is not fatal - the rows from the error body are still
  /// actionable - so it only raises a note, and the picker keeps working.
  Future<void> _enrich() async {
    try {
      final DevicesResult result = await widget.api.devices();
      if (!mounted) return;

      final Map<String, DeviceInfo> byId = <String, DeviceInfo>{
        for (final DeviceInfo device in result.devices)
          if (device.isActive) device.id: device,
      };

      // Keep the server's ordering from the 409 (most recently used first) and
      // only upgrade the rows in place, then append any active device the
      // error body did not mention.
      final List<_SlotRow> merged = <_SlotRow>[];
      final Set<String> seen = <String>{};
      for (final _SlotRow row in _rows) {
        final DeviceInfo? live = byId[row.id];
        if (live != null) {
          merged.add(_SlotRow.fromDevice(live, _ru));
          seen.add(row.id);
        }
      }
      for (final DeviceInfo device in result.devices) {
        if (!device.isActive || seen.contains(device.id)) continue;
        merged.add(_SlotRow.fromDevice(device, _ru));
      }

      setState(() {
        _rows = merged;
        _loading = false;
        _stale = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _stale = _rows.isNotEmpty;
        if (_rows.isEmpty) _error = widget.strings.deviceLimitEmpty;
      });
    }
  }

  /// Revokes the chosen device and re-registers this PC into the freed slot.
  ///
  /// The caller's [onRelease] clears the limit only after the re-registration
  /// succeeds, so a failure anywhere leaves this dialog open with the same
  /// list rather than closing on a promise it did not keep.
  Future<void> _release(_SlotRow row) async {
    if (_busyId != null) return;
    setState(() {
      _busyId = row.id;
      _error = null;
    });
    try {
      await widget.onRelease(row.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busyId = null;
        _error = widget.strings.deviceLimitFailed;
      });
    }
  }

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// "platform · connected now · via Frankfurt" - only the parts we actually
  /// know, so a sparse row never reads "· ·".
  String _subtitle(_SlotRow row) {
    final DesktopStrings s = widget.strings;
    final List<String> parts = <String>[];
    final String? platform = row.platform;
    if (platform != null && platform.isNotEmpty) parts.add(platform);
    if (row.isCurrent) parts.add(s.deviceLimitThisPc);
    if (row.connected) {
      parts.add(s.deviceLimitConnectedNow);
    }
    {
      final DateTime? seen = row.lastSeen;
      if (seen != null) {
        parts.add(
          s.deviceLimitLastSeen(
            '${_two(seen.day)}.${_two(seen.month)} '
            '${_two(seen.hour)}:${_two(seen.minute)}',
          ),
        );
      }
    }
    final String? node = row.nodeName;
    if (row.connected && node != null && node.isNotEmpty) {
      parts.add(s.deviceLimitVia(node));
    }
    return parts.join(' · ');
  }

  static IconData _platformIcon(String? platform) {
    final String p = (platform ?? '').toLowerCase();
    if (p.contains('android') || p.contains('ios') || p.contains('phone')) {
      return Icons.smartphone_rounded;
    }
    if (p.contains('chrome') ||
        p.contains('extension') ||
        p.contains('browser')) {
      return Icons.travel_explore_rounded;
    }
    if (p.contains('win') ||
        p.contains('mac') ||
        p.contains('linux') ||
        p.contains('desktop')) {
      return Icons.desktop_windows_rounded;
    }
    return Icons.devices_other_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final DesktopStrings s = widget.strings;

    return PopScope(
      // Closing mid-revoke would leave the user staring at a stale banner while
      // a device is being signed out behind their back.
      canPop: _busyId == null,
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DesktopTokens.cardRadius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              width: 468,
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              decoration: BoxDecoration(
                color: DesktopTokens.cardRaised.withOpacity(0.88),
                borderRadius: BorderRadius.circular(DesktopTokens.cardRadius),
                border: Border.all(color: GlukColors.danger.withOpacity(0.32)),
                boxShadow: DesktopTokens.glow(
                  GlukColors.danger,
                  blur: 40,
                  opacity: 0.16,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _header(s),
                  const SizedBox(height: 12),
                  Text(
                    s.deviceLimitBody,
                    style: const TextStyle(
                      color: GlukColors.text1,
                      fontSize: 12.5,
                      height: 1.35,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _list(s),
                  if (!_loading && !_stale && _rows.length < widget.details.maxDevices)
                    TextButton(onPressed: _busyId == null ? () => Navigator.of(context).pop(true) : null,
                      child: Text(_ru ? 'Слот уже свободен — продолжить' : 'A slot is available — continue')),
                  if (_stale) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      s.deviceLimitRefreshFailed,
                      style: const TextStyle(
                        color: GlukColors.text2,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        const Icon(
                          Icons.error_outline_rounded,
                          size: 15,
                          color: GlukColors.danger,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              color: GlukColors.danger,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: _busyId != null
                          ? null
                          : () => Navigator.of(context).pop(false),
                      child: Text(
                        s.cancel,
                        style: const TextStyle(
                          color: GlukColors.text2,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(DesktopStrings s) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: GlukColors.danger.withOpacity(0.14),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(
            Icons.devices_rounded,
            size: 18,
            color: GlukColors.danger,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            // The count comes from the account's real allowance: 1 on Free,
            // 3 on Basic, 5 on Pro. Hard-coding "5 / 5" would misreport what
            // a Basic subscriber actually bought.
            s.deviceLimitTitle(widget.details.usage),
            style: const TextStyle(
              color: GlukColors.text0,
              fontSize: 16,
              fontWeight: FontWeight.w800,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ],
    );
  }

  Widget _list(DesktopStrings s) {
    if (_rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GlukColors.violetLight,
                  ),
                )
              : Text(
                  s.deviceLimitEmpty,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 296),
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _rows.length,
        separatorBuilder: (BuildContext _, int __) => const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) =>
            _row(_rows[index], s),
      ),
    );
  }

  Widget _row(_SlotRow row, DesktopStrings s) {
    final bool busy = _busyId == row.id;
    final bool blocked = _busyId != null && !busy;
    final String subtitle = _subtitle(row);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: GlukColors.pageBg.withOpacity(0.55),
        borderRadius: BorderRadius.circular(DesktopTokens.innerRadius),
        border: Border.all(
          color: row.connected
              ? GlukColors.connected.withOpacity(0.28)
              : DesktopTokens.cardBorder,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            _platformIcon(row.platform),
            size: 18,
            color: row.connected ? GlukColors.connected : GlukColors.text1,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  row.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
                if (subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: GlukColors.text1,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (busy)
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: GlukColors.violetLight,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  s.deviceLimitReleasing,
                  style: const TextStyle(
                    color: GlukColors.text1,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            )
          else
            _ReleaseButton(
              label: s.deviceLimitFreeSlot,
              enabled: !blocked,
              onTap: () => _release(row),
            ),
        ],
      ),
    );
  }
}

/// Hover-lit pill, matching the home banner's buttons.
///
/// Not an [OutlinedButton]: the desktop theme removes ripples and hover
/// colours, so a stock button gives no feedback at all on a dark card.
class _ReleaseButton extends StatefulWidget {
  const _ReleaseButton({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ReleaseButton> createState() => _ReleaseButtonState();
}

class _ReleaseButtonState extends State<_ReleaseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color accent =
        widget.enabled ? GlukColors.danger : GlukColors.text2;

    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: accent.withOpacity(
              widget.enabled ? (_hovered ? 0.26 : 0.14) : 0.06,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: accent.withOpacity(0.45)),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: accent,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
