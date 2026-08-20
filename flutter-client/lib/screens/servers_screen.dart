import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../utils/geo.dart';
import '../widgets/glass.dart';

/// The server list from the mock-up: rounded rows, a 26 px radio, a flag disc
/// and one line of live node telemetry.
///
/// The mock-up shows a made-up "5.2 MB/sec" per row. That number cannot be
/// known before connecting, so it is replaced with figures the node actually
/// reports over its heartbeat: load, peer count and how long ago it checked in.
/// A server list that lies about throughput is worse than one that shows load.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key, this.onDone});

  /// Returns to the home tab after a server is picked.
  final VoidCallback? onDone;

  void _select(BuildContext context, VpnController vpn, VpnNodeInfo node) {
    final bool wasConnected = vpn.isConnected || vpn.isTransitioning;
    vpn.selectNode(node);
    // While a tunnel is up the controller refuses the switch and posts a
    // notice; staying on this screen keeps that message visible.
    if (!wasConnected) onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    final VpnController vpn = context.watch<VpnController>();
    final TextTheme text = Theme.of(context).textTheme;

    final List<VpnNodeInfo> recommended = vpn.nodes
        .where((VpnNodeInfo node) => node.connectable)
        .toList()
      ..sort((VpnNodeInfo a, VpnNodeInfo b) {
        final int byLoad = a.loadPercent.compareTo(b.loadPercent);
        return byLoad != 0 ? byLoad : a.country.compareTo(b.country);
      });
    final List<VpnNodeInfo> others = vpn.nodes
        .where((VpnNodeInfo node) => !node.connectable)
        .toList()
      ..sort((VpnNodeInfo a, VpnNodeInfo b) => a.country.compareTo(b.country));

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Row(
              children: <Widget>[
                if (onDone != null)
                  CircleIconButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: onDone!,
                    tooltip: 'Back',
                  ),
                if (onDone != null) const SizedBox(width: 14),
                Text('Servers', style: text.headlineSmall),
                const Spacer(),
                CircleIconButton(
                  icon: Icons.refresh_rounded,
                  onTap: vpn.loadNodes,
                  tooltip: 'Refresh',
                ),
              ],
            ),
          ),
          if (vpn.notice != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
              child: InkWell(
                onTap: vpn.clearMessages,
                child: InlineNotice(
                  message: vpn.notice!,
                  tone: GlukColors.violetLight,
                ),
              ),
            ),
          if (vpn.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
              child: InkWell(
                onTap: vpn.clearMessages,
                child: InlineNotice(message: vpn.error!),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: vpn.loadNodes,
              color: GlukColors.violetLight,
              backgroundColor: GlukColors.bg,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 108),
                children: <Widget>[
                  if (vpn.nodes.isEmpty && vpn.loadingNodes)
                    const Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  if (vpn.nodes.isEmpty && !vpn.loadingNodes)
                    const InlineNotice(
                      message:
                          'No nodes are registered on this control plane yet. '
                          'Enrol a node agent, then pull to refresh.',
                      tone: GlukColors.violetLight,
                    ),
                  if (recommended.isNotEmpty) ...<Widget>[
                    _SectionLabel(label: 'For You'),
                    const SizedBox(height: 10),
                    for (final VpnNodeInfo node in recommended)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _ServerTile(
                          node: node,
                          selected: vpn.selectedNode?.id == node.id,
                          onTap: () => _select(context, vpn, node),
                        ),
                      ),
                  ],
                  if (others.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    _SectionLabel(label: 'Other Servers'),
                    const SizedBox(height: 10),
                    for (final VpnNodeInfo node in others)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _ServerTile(
                          node: node,
                          selected: vpn.selectedNode?.id == node.id,
                          onTap: null,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium,
    );
  }
}

/// `.srv-row` - a fully rounded row with the flag disc on the left and the
/// radio on the right.
class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.node,
    required this.selected,
    required this.onTap,
  });

  final VpnNodeInfo node;
  final bool selected;
  final VoidCallback? onTap;

  String get _subtitle {
    if (!node.online) {
      return 'offline \u00b7 last heartbeat ${formatRelative(node.lastHeartbeat)}';
    }
    if (!node.connectable) {
      return '${node.status.toLowerCase()} \u00b7 not accepting peers';
    }
    return 'load ${node.loadPercent.round()}% \u00b7 '
        '${node.activePeers}/${node.capacity} peers \u00b7 '
        '${formatRelative(node.lastHeartbeat)}';
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Opacity(
      opacity: node.connectable ? 1 : 0.55,
      child: GlassPanel(
        radius: 999,
        padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            FlagCircle(flag: countryFlag(node.countryCode)),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(node.country, style: text.titleMedium),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '\u00b7 ${node.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            _Radio(selected: selected, enabled: node.connectable),
          ],
        ),
      ),
    );
  }
}

/// `.radio` - 26 px, violet-to-blue gradient with a tick when chosen.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: GlukSizes.radio,
      height: GlukSizes.radio,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: selected ? GlukGradients.arrow : null,
        color: selected ? null : Colors.transparent,
        border: selected
            ? null
            : Border.all(
                color: enabled ? GlukColors.stroke : GlukColors.text2,
                width: 1.4,
              ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 15, color: GlukColors.bg)
          : null,
    );
  }
}
