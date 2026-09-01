import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../widgets/glass.dart';

/// ROUND 10 (4.2): the "Account" screen the desktop client and the website
/// already had - profile, plan, and the live sessions with a way to end them.
///
/// One deliberate naming decision. The server has no separate "session" object
/// a user could act on: a session belongs to a registered device, and revoking
/// the device is what closes the tunnel and removes the WireGuard peer from the
/// node. So the list is built from `GET /api/devices` and each row says what it
/// is really doing. Inventing a session list that cannot be revoked, next to a
/// device list that can, would only teach people to distrust the buttons.
///
/// Settings keeps the plain device manager for the case where somebody just
/// wants to free a slot; this screen is the account overview.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _loading = true;
  String? _error;
  DevicesResult? _devices;
  String? _revoking;

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
    // Both, in one pull-to-refresh: a stale plan next to a fresh session list
    // is how "my subscription is active" arguments start.
    await auth.refreshMe();
    try {
      final DevicesResult result = await auth.loadDevices();
      if (!mounted) return;
      setState(() {
        _devices = result;
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
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        backgroundColor: GlukColors.bg,
        title: Text('Revoke ${device.deviceName}?'),
        content: Text(
          device.isCurrent
              ? 'This is the phone you are holding. The tunnel is closed, the '
                'WireGuard peer is removed from the node and a fresh key pair '
                'is registered right away, so you stay signed in.'
              : 'The session is closed and the WireGuard peer is removed from '
                'the node. That device has to sign in again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final AuthController auth = context.read<AuthController>();
    final VpnController vpn = context.read<VpnController>();
    setState(() => _revoking = device.id);
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
      if (mounted) setState(() => _revoking = null);
    }
  }

  void _copy(String value, String said) {
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(said)));
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AuthController auth = context.watch<AuthController>();
    final AuthUser? user = auth.user;
    final SubscriptionInfo? plan = auth.subscription;

    final List<DeviceInfo> all = _devices?.devices ?? const <DeviceInfo>[];
    final List<DeviceInfo> active =
        all.where((DeviceInfo d) => d.isActive).toList();
    final List<DeviceInfo> revoked =
        all.where((DeviceInfo d) => !d.isActive).toList();

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      appBar: AppBar(
        title: const Text('Account'),
        backgroundColor: Colors.transparent,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Reload',
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
            if (auth.sessionUnconfirmed) ...<Widget>[
              const InlineNotice(
                message: 'Showing the last known state \u2014 the server has '
                    'not confirmed this session yet.',
              ),
              const SizedBox(height: 14),
            ],

            // --- profile ---------------------------------------------------
            _Card(
              title: 'Profile',
              children: <Widget>[
                _Row(label: 'Username', value: user?.username ?? '\u2014'),
                _Row(
                  label: 'Email',
                  value: user?.email ?? 'not set',
                  trailing: user?.email == null
                      ? null
                      : _Pill(
                          label: (user?.emailVerified ?? false)
                              ? 'verified'
                              : 'unverified',
                          tone: (user?.emailVerified ?? false)
                              ? GlukColors.connected
                              : GlukColors.amber,
                        ),
                ),
                _Row(
                  label: 'Account number',
                  value: (user?.publicId ?? '').isEmpty
                      ? '\u2014'
                      : user!.publicId,
                  mono: true,
                  onTapValue: (user?.publicId ?? '').isEmpty
                      ? null
                      : () => _copy(user!.publicId, 'Account ID copied'),
                ),
                _Row(label: 'Status', value: user?.status.toLowerCase() ?? '\u2014'),
                if ((user?.originLabel ?? '').isNotEmpty)
                  _Row(label: 'Signed up from', value: user!.originLabel!),
                _Row(label: 'Member since', value: formatDateTime(user?.createdAt)),
              ],
            ),
            const SizedBox(height: 12),

            // --- subscription ----------------------------------------------
            _Card(
              title: 'Subscription',
              trailing: _Pill(
                label: auth.subscriptionActive
                    ? 'active'
                    : (plan?.status.toLowerCase() ?? 'none'),
                tone: auth.subscriptionActive
                    ? GlukColors.connected
                    : GlukColors.amber,
              ),
              children: <Widget>[
                _Row(
                  label: 'Valid until',
                  value: plan?.expiresAt == null
                      ? '\u2014'
                      : formatDateTime(plan!.expiresAt),
                ),
                _Row(
                  label: 'Device slots',
                  value: '${active.length} of '
                      '${_devices?.maxDevices ?? user?.maxDevices ?? 3} in use',
                ),
                _Row(
                  label: 'Tunnels at once',
                  value: '${user?.maxConcurrentSessions ?? 1}',
                ),
                if (!auth.subscriptionActive) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Without an active plan the servers refuse new tunnels. '
                    'Nothing on the account is deleted.',
                    style: text.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 20),

            // --- sessions ---------------------------------------------------
            Row(
              children: <Widget>[
                Text('ACTIVE SESSIONS', style: text.labelMedium),
                const Spacer(),
                if (_loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (active.isEmpty && !_loading)
              Text(
                'No devices are signed in.',
                style: text.bodySmall,
              ),
            for (final DeviceInfo device in active) ...<Widget>[
              _SessionRow(
                device: device,
                revoking: _revoking == device.id,
                onRevoke: _revoking == null ? () => _revoke(device) : null,
              ),
              const SizedBox(height: 8),
            ],
            if (revoked.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              Text('REVOKED', style: text.labelMedium),
              const SizedBox(height: 8),
              for (final DeviceInfo device in revoked) ...<Widget>[
                _SessionRow(device: device, revoking: false),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 16),
            Text(
              'Revoking closes the tunnel and removes the WireGuard peer from '
              'the node. Byte counters and session times are kept for '
              'accounting \u2014 addresses and payloads never are.',
              style: text.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// One signed-in device, presented as the session it carries.
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.device,
    required this.revoking,
    this.onRevoke,
  });

  final DeviceInfo device;
  final bool revoking;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
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
              _iconFor(device.platform),
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
                            ? 'unnamed device'
                            : device.deviceName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium,
                      ),
                    ),
                    if (device.isCurrent) ...<Widget>[
                      const SizedBox(width: 8),
                      const _Pill(
                        label: 'this device',
                        tone: GlukColors.violetLight,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  live
                      ? 'Connected via ${device.connectedNodeName ?? 'a node'}'
                      : device.isActive
                          ? 'Signed in \u00b7 last seen '
                              '${formatRelative(device.lastSeen)}'
                          : 'Revoked',
                  style: text.bodySmall,
                ),
                Text(
                  '${device.platform ?? 'unknown platform'} \u00b7 registered '
                  '${formatDateTime(device.createdAt)}',
                  style: text.bodySmall?.copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          if (device.isActive)
            TextButton(
              onPressed: revoking ? null : onRevoke,
              style: TextButton.styleFrom(foregroundColor: GlukColors.danger),
              child: revoking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Revoke'),
            ),
        ],
      ),
    );
  }

  static IconData _iconFor(String? platform) {
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

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title.toUpperCase(), style: text.labelMedium),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.mono = false,
    this.trailing,
    this.onTapValue,
  });

  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;
  final VoidCallback? onTapValue;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget shown = Text(
      value,
      textAlign: TextAlign.right,
      style: (mono ? text.bodySmall : text.bodyMedium)?.copyWith(
        color: GlukColors.text0,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: onTapValue == null
                ? shown
                : InkWell(onTap: onTapValue, child: shown),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});

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
