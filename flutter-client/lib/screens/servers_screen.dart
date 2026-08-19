import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/vpn_controller.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final VpnController vpn = context.watch<VpnController>();
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Servers'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload nodes',
            onPressed: vpn.loadingNodes ? null : () => vpn.loadNodes(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: vpn.loadNodes,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            if (vpn.loadingNodes && vpn.nodes.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!vpn.loadingNodes && vpn.nodes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Column(
                  children: <Widget>[
                    Icon(Icons.dns_outlined, size: 48, color: scheme.onSurfaceVariant),
                    const SizedBox(height: 14),
                    const Text(
                      'No nodes yet',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Run the node agent enrolment on the VPN server, then pull '
                      'down to refresh.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            for (final VpnNodeInfo node in vpn.nodes)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _NodeCard(
                  node: node,
                  selected: vpn.selectedNode?.id == node.id,
                  onTap: () => vpn.selectNode(node),
                ),
              ),
            if (vpn.nodes.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Load is the number of active WireGuard peers against the node '
                  'capacity. A node goes OFFLINE when its heartbeat stops.',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NodeCard extends StatelessWidget {
  const _NodeCard({required this.node, required this.selected, required this.onTap});

  final VpnNodeInfo node;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(countryFlag(node.countryCode), style: const TextStyle(fontSize: 30)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          node.country,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          node.name,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          StatusDot(online: node.online),
                          const SizedBox(width: 6),
                          Text(
                            node.status.toLowerCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: node.online ? scheme.primary : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (selected)
                        Row(
                          children: <Widget>[
                            Icon(Icons.check_circle, size: 14, color: scheme.primary),
                            const SizedBox(width: 4),
                            Text(
                              'selected',
                              style: TextStyle(fontSize: 11, color: scheme.primary),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LoadBar(percent: node.loadPercent),
              const SizedBox(height: 12),
              KeyValueRow(label: 'Endpoint', value: node.endpoint, mono: true),
              KeyValueRow(label: 'Peers', value: '${node.activePeers} / ${node.capacity}'),
              KeyValueRow(label: 'CPU', value: formatPercent(node.cpuPercent)),
              KeyValueRow(label: 'RAM', value: formatPercent(node.ramPercent)),
              KeyValueRow(label: 'Uptime', value: formatUptime(node.uptimeSeconds)),
              KeyValueRow(label: 'Heartbeat', value: formatRelative(node.lastHeartbeat)),
              if (node.agentVersion != null)
                KeyValueRow(label: 'Agent', value: node.agentVersion!),
              if (!node.connectable)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    'This node cannot accept connections right now.',
                    style: TextStyle(fontSize: 11, color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
