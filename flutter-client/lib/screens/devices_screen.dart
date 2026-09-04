import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../widgets/glass.dart';
import '../widgets/page_background.dart';

/// Every device registered against the account, with a way to end any of them.
///
/// ROUND 11: this screen and the Account screen were showing the same list in
/// two different designs - a raw `Card` with four `KeyValueRow`s here, and a
/// far better glass row over there. The good one won and moved in; Account has
/// stopped listing devices at all and now links here instead. One list, one
/// design, one place to revoke from.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  String? _error;
  DevicesResult? _result;
  String? _revokingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AuthController auth = context.read<AuthController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DevicesResult result = await auth.loadDevices();
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(DeviceInfo device) async {
    final AppStrings s = context.strings;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: GlukColors.bg,
        title: Text(s.revokeDeviceTitle(
          device.deviceName.isEmpty ? s.thisDevice : device.deviceName,
        )),
        content: Text(
          device.isCurrent ? s.revokeCurrentBody : s.revokeOtherBody,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(s.revoke),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final AuthController auth = context.read<AuthController>();
    final VpnController vpn = context.read<VpnController>();
    setState(() => _revokingId = device.id);
    try {
      // Local tunnel first: leaving a dead interface up after the peer is gone
      // looks exactly like "the VPN broke".
      if (device.isCurrent && vpn.isConnected) await vpn.disconnect();
      await auth.revokeDevice(device.id);
      if (device.isCurrent && mounted) await auth.ensureDeviceRegistered();
      if (!mounted) return;
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final List<DeviceInfo> all = _result?.devices ?? const <DeviceInfo>[];
    final List<DeviceInfo> active =
        all.where((DeviceInfo device) => device.isActive).toList();
    final List<DeviceInfo> revoked =
        all.where((DeviceInfo device) => !device.isActive).toList();

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      body: PageBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(s.devices),
            backgroundColor: Colors.transparent,
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.refresh_rounded),
                tooltip: s.reload,
                onPressed: _loading ? null : _load,
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: <Widget>[
                if (_error != null) ...<Widget>[
                  InkWell(
                    onTap: () => setState(() => _error = null),
                    child: InlineNotice(message: _error!),
                  ),
                  const SizedBox(height: 14),
                ],
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _result == null
                            ? ''
                            : s.slotsInUse(active.length, _result!.maxDevices),
                        style: text.labelMedium,
                      ),
                    ),
                    if (_loading)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (active.isEmpty && !_loading)
                  Text(s.noDevicesRegistered, style: text.bodySmall),
                for (final DeviceInfo device in active) ...<Widget>[
                  SessionRow(
                    device: device,
                    revoking: _revokingId == device.id,
                    onRevoke:
                        _revokingId == null ? () => _revoke(device) : null,
                  ),
                  const SizedBox(height: 8),
                ],
                if (revoked.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(s.revoked.toUpperCase(), style: text.labelMedium),
                  const SizedBox(height: 8),
                  for (final DeviceInfo device in revoked) ...<Widget>[
                    SessionRow(device: device, revoking: false),
                    const SizedBox(height: 8),
                  ],
                ],
                const SizedBox(height: 16),
                Text(s.revokeNotice, style: text.bodySmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One registered device, presented as the session it carries.
///
/// ROUND 11: moved here from `account_screen.dart` and made public, because it
/// is the design that should have been on this screen all along. A platform
/// disc, the name, one plain-language line about what the device is doing right
/// now, and the technical detail underneath in small type - rather than four
/// label/value rows that make a phone look like a database record.
class SessionRow extends StatelessWidget {
  const SessionRow({
    super.key,
    required this.device,
    required this.revoking,
    this.onRevoke,
  });

  final DeviceInfo device;
  final bool revoking;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final bool live = device.connected;

    return GlassPanel(
      radius: GlukSizes.cellRadius,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (live ? GlukColors.connected : GlukColors.violet)
                  .withOpacity(0.16),
            ),
            child: Icon(
              iconFor(device.platform),
              size: 16,
              color: live ? GlukColors.connected : GlukColors.violetLight,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        device.deviceName.isEmpty
                            ? s.unknownPlatform
                            : device.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                    ),
                    if (device.isCurrent) ...<Widget>[
                      const SizedBox(width: 8),
                      TonePill(
                        label: s.thisDevice,
                        tone: GlukColors.violetLight,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  live
                      ? s.connectedVia(device.connectedNodeName ?? '\u2014')
                      : device.isActive
                          ? '${s.signedIn} \u00b7 ${s.lastSeen} '
                              '${s.relativeTime(device.lastSeen)}'
                          : s.revoked,
                  style: text.bodySmall,
                ),
                Text(
                  '${device.platform ?? s.unknownPlatform} \u00b7 '
                  '${s.registeredOn} ${formatDateTime(device.createdAt)}',
                  style: text.bodySmall?.copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (device.isActive && onRevoke != null)
            TextButton(
              onPressed: revoking ? null : onRevoke,
              style: TextButton.styleFrom(foregroundColor: GlukColors.danger),
              child: revoking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(s.revoke),
            ),
        ],
      ),
    );
  }

  /// Windows, the browser extension and a phone must be tellable apart at a
  /// glance - that is the whole reason the platform is recorded at all.
  static IconData iconFor(String? platform) {
    final String value = (platform ?? '').toLowerCase();
    if (value.contains('windows')) return Icons.desktop_windows_rounded;
    if (value.contains('chrome') || value.contains('extension')) {
      return Icons.extension_rounded;
    }
    if (value.contains('android') || value.contains('ios')) {
      return Icons.smartphone_rounded;
    }
    return Icons.devices_other_rounded;
  }
}

/// A status word, not a database enum: lower case, tinted, pill-shaped.
///
/// Public and shared by Devices, Account and Settings, which each had their own
/// private copy of exactly these fifteen lines.
class TonePill extends StatelessWidget {
  const TonePill({super.key, required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.40)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: tone, fontSize: 10),
      ),
    );
  }
}
