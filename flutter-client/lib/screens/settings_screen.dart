import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/channel_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../widgets/glass.dart';
import 'devices_screen.dart';

/// Account, channel and diagnostics.
///
/// Two things here are deliberate product decisions rather than decoration:
///
///  * the nickname is editable, the account ID is not. The ID is the handle
///    support and admins search and ban by, so it is assigned by the database
///    and enforced immutable there - a renamed user is still the same account.
///  * the PROD/BETA switch is only offered while disconnected. Repointing the
///    app at another control plane mid-tunnel would leave a peer installed on a
///    node that the app can no longer talk to.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final AuthController auth = context.watch<AuthController>();
    final ChannelController channel = context.watch<ChannelController>();
    final MotionController motion = context.watch<MotionController>();
    final VpnController vpn = context.watch<VpnController>();
    final AuthUser? user = auth.user;
    final SubscriptionInfo? subscription = auth.subscription;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 108),
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('Settings', style: text.headlineSmall),
              const Spacer(),
              CircleIconButton(
                icon: Icons.refresh_rounded,
                onTap: () {
                  auth.refreshMe();
                  channel.probeAll();
                },
                tooltip: 'Refresh',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (auth.error != null) ...<Widget>[
            InkWell(
              onTap: auth.clearError,
              child: InlineNotice(message: auth.error!),
            ),
            const SizedBox(height: 12),
          ],
          _AccountPanel(user: user, subscription: subscription),
          const SizedBox(height: 12),
          _Panel(
            title: 'Subscription',
            children: <Widget>[
              _Row(
                label: 'Status',
                value: subscription?.status.toLowerCase() ?? '\u2014',
                valueColor: auth.subscriptionActive
                    ? GlukColors.connected
                    : GlukColors.amber,
              ),
              _Row(
                label: 'Expires',
                value: formatDateTime(subscription?.expiresAt),
              ),
              _Row(label: 'Max devices', value: '${user?.maxDevices ?? 0}'),
            ],
          ),
          const SizedBox(height: 12),
          _DevicesPanel(auth: auth),
          const SizedBox(height: 12),
          if (channel.canSwitch) ...<Widget>[
            _ChannelPanel(channel: channel, vpn: vpn),
            const SizedBox(height: 12),
          ],
          _Panel(
            title: 'This build',
            children: <Widget>[
              _Row(label: 'Channel', value: channel.active.label),
              _Row(label: 'Control API', value: channel.baseUrl, mono: true),
              _Row(
                label: 'Server version',
                value: channel.versionOf(channel.active)?.version ?? '\u2014',
              ),
              _Row(
                label: 'Migration',
                value: channel.versionOf(channel.active)?.migration ?? '\u2014',
                mono: true,
              ),
              _Row(label: 'Tunnel interface', value: AppConfig.tunnelInterfaceName),
              _Row(label: 'App id', value: AppConfig.appId, mono: true),
            ],
          ),
          const SizedBox(height: 12),
          _Panel(
            title: 'Animations',
            children: <Widget>[
              _Row(
                label: 'Motion',
                value: motion.reduceMotion ? 'reduced' : 'full',
                valueColor:
                    motion.reduceMotion ? GlukColors.amber : GlukColors.connected,
              ),
              if (motion.reduceMotion)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Looping animations are frozen at a representative frame: '
                    '${motion.reduceMotionReason}. The map, the glow and the '
                    'globe still render, they just stop moving.',
                    style: text.bodySmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          _LogoutButton(auth: auth, vpn: vpn),
          const SizedBox(height: 14),
          Text(
            'GlukVPN is a personal test service. Traffic accounting records only '
            'byte counters and session times \u2014 never addresses, URLs or '
            'payloads.',
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _AccountPanel extends StatelessWidget {
  const _AccountPanel({required this.user, required this.subscription});

  final AuthUser? user;
  final SubscriptionInfo? subscription;

  Future<void> _rename(BuildContext context) async {
    final AuthController auth = context.read<AuthController>();
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _RenameDialog(current: user?.username ?? ''),
    );
    if (next == null || next.isEmpty) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final UsernameChangeResult result = await auth.api.changeUsername(next);
      await auth.refreshMe();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.changed
                ? 'Nickname is now ${result.username}'
                : 'That is already your nickname',
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String name = user?.username ?? '\u2014';
    final String initial =
        name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return _Panel(
      title: 'Account',
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: GlukGradients.arrow,
              ),
              child: Text(
                initial,
                style: text.titleLarge?.copyWith(color: GlukColors.bg),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(name, style: text.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    user?.publicIdLabel ?? 'ID unavailable',
                    style: text.bodySmall?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if ((user?.publicId ?? '').isNotEmpty)
              CircleIconButton(
                icon: Icons.copy_rounded,
                tooltip: 'Copy account ID',
                size: 34,
                onTap: () {
                  Clipboard.setData(ClipboardData(text: user!.publicId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Account ID copied')),
                  );
                },
              ),
            const SizedBox(width: 8),
            CircleIconButton(
              icon: Icons.edit_rounded,
              tooltip: 'Change nickname',
              size: 34,
              onTap: () => _rename(context),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _Row(label: 'Status', value: user?.status.toLowerCase() ?? '\u2014'),
        _Row(label: 'Created', value: formatDateTime(user?.createdAt)),
        const SizedBox(height: 8),
        Text(
          'The nickname can change whenever you like. The account ID is issued '
          'once by the database and can never change \u2014 it is what admins '
          'search, ban and audit by.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GlukColors.bg,
      title: const Text('Change nickname'),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Nickname'),
          validator: (String? value) {
            final String text = (value ?? '').trim();
            if (text.length < AppConfig.minUsernameLength) {
              return 'At least ${AppConfig.minUsernameLength} characters';
            }
            if (text.length > AppConfig.maxUsernameLength) {
              return 'At most ${AppConfig.maxUsernameLength} characters';
            }
            return null;
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(_controller.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _DevicesPanel extends StatelessWidget {
  const _DevicesPanel({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'This device',
      children: <Widget>[
        _Row(label: 'Name', value: auth.deviceName ?? '\u2014'),
        _Row(
          label: 'Device id',
          value: _short(auth.deviceId),
          mono: true,
        ),
        _Row(
          label: 'WireGuard key',
          value: auth.devicePublicKey == null
              ? 'not generated yet'
              : '${_short(auth.devicePublicKey, 12)} (public)',
          mono: true,
        ),
        const SizedBox(height: 10),
        PrimaryPillButton(
          label: 'Manage devices',
          icon: Icons.devices_other_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const DevicesScreen(),
            ),
          ),
        ),
      ],
    );
  }

  static String _short(String? value, [int length = 8]) {
    if (value == null || value.isEmpty) return '\u2014';
    return value.length <= length ? value : '${value.substring(0, length)}\u2026';
  }
}

/// PROD / BETA. The two channels are separate deployments with separate
/// databases, so this is a channel switch, not a URL toggle: accounts, devices
/// and sessions do not carry over.
class _ChannelPanel extends StatelessWidget {
  const _ChannelPanel({required this.channel, required this.vpn});

  final ChannelController channel;
  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool locked = vpn.isConnected || vpn.isTransitioning;
    final ChannelVersion? prod = channel.versionOf(AppChannel.prod);
    final ChannelVersion? beta = channel.versionOf(AppChannel.beta);
    final String? betaProblem = channel.unreachableReason(AppChannel.beta);

    return _Panel(
      title: 'Channel',
      trailing: channel.probing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          : null,
      children: <Widget>[
        _Row(
          label: 'Production',
          value: prod?.version ?? 'unreachable',
          valueColor: prod == null ? GlukColors.amber : GlukColors.text0,
        ),
        _Row(
          label: 'Beta',
          value: beta?.version ?? 'off',
          valueColor: beta == null ? GlukColors.text2 : GlukColors.amber,
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                channel.isBeta ? 'Using BETA' : 'Using PRODUCTION',
                style: text.titleMedium?.copyWith(
                  color: channel.isBeta ? GlukColors.amber : GlukColors.text0,
                ),
              ),
            ),
            if (channel.switching)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(
                value: channel.isBeta,
                activeColor: GlukColors.amber,
                onChanged: locked || (!channel.betaReachable && !channel.isBeta)
                    ? null
                    : (bool value) => channel.setBetaEnabled(value),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          locked
              ? 'Disconnect first: switching channel while a tunnel is up would '
                'leave a peer installed on a node this app can no longer reach.'
              : channel.betaReachable || channel.isBeta
                  ? 'BETA is a separate deployment: its own database, its own '
                    'WireGuard node (wg1 on UDP 51821) and its own accounts. '
                    'Your PROD session stays signed in.'
                  : 'BETA is not answering right now'
                    '${betaProblem == null ? '' : ': $betaProblem'}.',
          style: text.bodySmall,
        ),
        if (channel.error != null) ...<Widget>[
          const SizedBox(height: 10),
          InkWell(
            onTap: channel.clearError,
            child: InlineNotice(message: channel.error!),
          ),
        ],
      ],
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.auth, required this.vpn});

  final AuthController auth;
  final VpnController vpn;

  Future<void> _logout(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: GlukColors.bg,
        title: const Text('Sign out?'),
        content: const Text(
          'The tunnel is closed, this device is revoked on the server and its '
          'peer is removed from the node.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (vpn.isConnected) await vpn.disconnect();
    await auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.symmetric(vertical: 14),
      onTap: auth.busy ? null : () => _logout(context),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.logout_rounded, size: 17, color: GlukColors.danger),
          const SizedBox(width: 8),
          Text(
            'Sign out',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: GlukColors.danger),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.children, this.trailing});

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
    this.valueColor,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: (mono ? text.bodySmall : text.bodyMedium)?.copyWith(
                color: valueColor ?? GlukColors.text0,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
