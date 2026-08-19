import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../utils/format.dart';
import '../widgets/common.dart';
import 'devices_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// Short, non-sensitive preview of an identifier or a public key.
  static String _short(String? value, [int keep = 12]) {
    if (value == null || value.isEmpty) return '--';
    if (value.length <= keep) return value;
    return '${value.substring(0, keep)}...';
  }

  Future<void> _signOut(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'The tunnel is closed, this device is revoked on the server and its '
          'WireGuard peer is removed. A fresh key pair is generated the next time '
          'you sign in.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final VpnController vpn = context.read<VpnController>();
    final AuthController auth = context.read<AuthController>();
    await vpn.disconnect();
    await auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = context.watch<AuthController>();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AuthUser? user = auth.user;
    final SubscriptionInfo? subscription = auth.subscription;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: <Widget>[
          if (auth.error != null)
            MessageBanner(message: auth.error!, isError: true, onDismiss: auth.clearError),
          SectionCard(
            title: 'ACCOUNT',
            children: <Widget>[
              KeyValueRow(label: 'Username', value: user?.username ?? '--'),
              KeyValueRow(label: 'Status', value: user?.status.toLowerCase() ?? '--'),
              if (user?.isAdmin ?? false)
                const KeyValueRow(label: 'Role', value: 'admin'),
              KeyValueRow(label: 'Max devices', value: '${user?.maxDevices ?? 0}'),
              KeyValueRow(
                label: 'Max concurrent sessions',
                value: '${user?.maxConcurrentSessions ?? 0}',
              ),
              KeyValueRow(label: 'Created', value: formatDateTime(user?.createdAt)),
            ],
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'SUBSCRIPTION',
            children: <Widget>[
              KeyValueRow(
                label: 'Status',
                value: subscription?.status.toLowerCase() ?? 'none',
              ),
              KeyValueRow(label: 'Expires', value: formatDateTime(subscription?.expiresAt)),
              const SizedBox(height: 6),
              Text(
                'Without an active subscription the server refuses new connections '
                'and closes the current session.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'THIS DEVICE',
            children: <Widget>[
              KeyValueRow(label: 'Name', value: auth.deviceName ?? '--'),
              KeyValueRow(label: 'Device id', value: _short(auth.deviceId, 8), mono: true),
              KeyValueRow(
                label: 'WireGuard public key',
                value: _short(auth.devicePublicKey),
                mono: true,
              ),
              const SizedBox(height: 6),
              Text(
                'The matching private key is generated on this phone, stored in the '
                'Android Keystore and never sent to the server or written to logs.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              leading: const Icon(Icons.devices_other_outlined),
              title: const Text('Devices'),
              subtitle: const Text('See and revoke registered devices'),
              trailing: const Icon(Icons.chevron_right),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SectionCard(
            title: 'CONNECTION',
            children: <Widget>[
              KeyValueRow(label: 'Control API', value: AppConfig.apiBaseUrl, mono: true),
              KeyValueRow(label: 'Tunnel interface', value: AppConfig.tunnelInterfaceName),
              KeyValueRow(label: 'App id', value: AppConfig.appId, mono: true),
              const SizedBox(height: 6),
              Text(
                'Only control traffic goes to the API. VPN traffic goes straight '
                'from this phone to the selected node.',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 22),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: Colors.white,
            ),
            onPressed: auth.busy ? null : () => _signOut(context),
            child: const Text('LOG OUT'),
          ),
        ],
      ),
    );
  }
}
