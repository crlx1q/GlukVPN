import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/ping_service.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final VpnController vpn = context.watch<VpnController>();
    final AuthController auth = context.watch<AuthController>();
    final VpnNodeInfo? node = vpn.selectedNode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('GlukVPN'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: _SubscriptionChip(subscription: auth.subscription)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await vpn.loadNodes();
          await vpn.refreshStatus();
          await auth.refreshMe();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            if (vpn.error != null)
              MessageBanner(
                message: vpn.error!,
                isError: true,
                onDismiss: vpn.clearMessages,
              ),
            if (vpn.notice != null)
              MessageBanner(message: vpn.notice!, onDismiss: vpn.clearMessages),
            if (!auth.subscriptionActive)
              const MessageBanner(
                message: 'Subscription is not active. The server refuses new '
                    'connections until it is renewed.',
                isError: true,
              ),
            if (node == null && !vpn.loadingNodes)
              const MessageBanner(
                message: 'No VPN node is registered yet. Enrol the node agent, '
                    'then pull to refresh.',
              ),
            const SizedBox(height: 6),
            _ConnectOrb(vpn: vpn),
            const SizedBox(height: 20),
            _CountryRow(node: node, session: vpn.session),
            const SizedBox(height: 22),
            _StatsGrid(vpn: vpn),
            const SizedBox(height: 14),
            _TrafficCard(vpn: vpn),
            const SizedBox(height: 14),
            _ConnectionCard(vpn: vpn, node: node),
            const SizedBox(height: 22),
            _ActionButton(vpn: vpn),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionChip extends StatelessWidget {
  const _SubscriptionChip({this.subscription});

  final SubscriptionInfo? subscription;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool active = subscription?.isActive ?? false;
    final Color color = active ? scheme.primary : scheme.error;
    final String label = subscription == null
        ? 'no plan'
        : active
            ? 'active'
            : subscription!.status.toLowerCase();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The big tappable status circle.
class _ConnectOrb extends StatelessWidget {
  const _ConnectOrb({required this.vpn});

  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool connected = vpn.isConnected;
    final bool busy = vpn.isTransitioning || vpn.busy;
    final Color color = connected
        ? scheme.primary
        : busy
            ? const Color(0xFFFFC15E)
            : scheme.onSurfaceVariant;

    return Center(
      child: GestureDetector(
        onTap: busy
            ? null
            : () {
                if (connected) {
                  vpn.disconnect();
                } else {
                  vpn.connect();
                }
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 210,
          height: 210,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withValues(alpha: 0.10),
            border: Border.all(color: color.withValues(alpha: 0.65), width: 3),
            boxShadow: connected
                ? <BoxShadow>[
                    BoxShadow(
                      color: color.withValues(alpha: 0.30),
                      blurRadius: 30,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                connected ? Icons.shield : Icons.shield_outlined,
                size: 56,
                color: color,
              ),
              const SizedBox(height: 12),
              Text(
                vpn.statusLabel.toUpperCase(),
                style: TextStyle(
                  fontSize: 15,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: color),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountryRow extends StatelessWidget {
  const _CountryRow({this.node, this.session});

  final VpnNodeInfo? node;
  final VpnSessionInfo? session;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Prefer what the live session reports, falling back to the selected node.
    final String countryCode = session?.nodeCountryCode ?? node?.countryCode ?? '';
    final String country = session?.nodeCountry ?? node?.country ?? 'No server';
    final String name = session?.nodeName ?? node?.name ?? '--';

    return Column(
      children: <Widget>[
        Text(
          '${countryFlag(countryCode)}  $country',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(name, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.vpn});

  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final PingSample sample = vpn.ping;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.55,
      children: <Widget>[
        StatTile(
          icon: Icons.public,
          label: 'Public IP',
          value: vpn.exitIp ?? '--',
          hint: vpn.isConnected ? 'seen from the internet' : 'not tunnelled',
        ),
        StatTile(
          icon: Icons.vpn_lock_outlined,
          label: 'VPN IP',
          value: vpn.assignedIp ?? '--',
        ),
        StatTile(
          icon: Icons.timer_outlined,
          label: 'Duration',
          value: formatDuration(vpn.connectedFor),
        ),
        StatTile(
          icon: Icons.speed_outlined,
          label: 'Ping',
          value: formatPing(sample.milliseconds),
          hint: 'via ${sample.sourceLabel}',
        ),
      ],
    );
  }
}

class _TrafficCard extends StatelessWidget {
  const _TrafficCard({required this.vpn});

  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SectionCard(
      title: 'TRAFFIC',
      children: <Widget>[
        KeyValueRow(label: 'Downloaded', value: formatBytes(vpn.bytesRx)),
        KeyValueRow(label: 'Uploaded', value: formatBytes(vpn.bytesTx)),
        KeyValueRow(
          label: 'Total',
          value: formatBytes(vpn.bytesRx + vpn.bytesTx),
        ),
        const SizedBox(height: 6),
        Text(
          'Byte counters come from WireGuard on the node and are reported every '
          '30 seconds. Only volumes are recorded, never content.',
          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.vpn, this.node});

  final VpnController vpn;
  final VpnNodeInfo? node;

  @override
  Widget build(BuildContext context) {
    final VpnSessionInfo? session = vpn.session;
    return SectionCard(
      title: 'CONNECTION',
      children: <Widget>[
        KeyValueRow(
          label: 'Endpoint',
          value: vpn.tunnel?.endpoint ?? node?.endpoint ?? '--',
          mono: true,
        ),
        KeyValueRow(
          label: 'Peer on node',
          value: vpn.peerReady ? 'installed' : (session == null ? '--' : 'pending'),
        ),
        KeyValueRow(label: 'Session', value: session?.status.toLowerCase() ?? '--'),
        KeyValueRow(
          label: 'Last handshake',
          value: session == null ? '--' : formatRelative(session.lastHandshakeAt),
        ),
        KeyValueRow(label: 'Tunnel stage', value: vpn.tunnelStage.name),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.vpn});

  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool connected = vpn.isConnected;
    final bool busy = vpn.isTransitioning || vpn.busy;

    return FilledButton(
      style: connected
          ? FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: Colors.white,
            )
          : null,
      onPressed: busy
          ? null
          : () {
              if (connected) {
                vpn.disconnect();
              } else {
                vpn.connect();
              }
            },
      child: Text(
        busy ? '${vpn.statusLabel.toUpperCase()}...' : (connected ? 'DISCONNECT' : 'CONNECT'),
      ),
    );
  }
}
