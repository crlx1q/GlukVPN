import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/ping_service.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/geo.dart';
import '../widgets/glass.dart';

/// The server list: rounded rows, a 26 px radio, a flag disc and the signal
/// bars on the right.
///
/// Everything a row shows about a place - country, city, region, flag code -
/// comes from the node record on the control plane, never from a table baked
/// into the app. Adding DE-02 or US-01 later needs no client release.
///
/// Internal handles (`de-01`) stay out of this screen entirely; they are an
/// admin and debug concern.
///
/// The mock-up shows a made-up "5.2 MB/sec" per row. Throughput cannot be known
/// before connecting, so the row carries figures that are real: the load the
/// node reports over its heartbeat, and a live ICMP round-trip to the node's
/// ping target measured from this phone.
class ServersScreen extends StatefulWidget {
  const ServersScreen({super.key, this.onDone});

  /// Returns to the home tab after a server is picked.
  final VoidCallback? onDone;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

class _ServersScreenState extends State<ServersScreen> {
  final PingService _ping = PingService();
  final Map<String, PingSample> _samples = <String, PingSample>{};
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeAll());
  }

  @override
  void dispose() {
    _ping.close();
    super.dispose();
  }

  /// One ICMP sample per node, sequentially: a handful of pings in a row is
  /// cheap, a burst of parallel ones on mobile data is not.
  Future<void> _probeAll() async {
    if (_probing) return;
    _probing = true;
    try {
      final List<VpnNodeInfo> nodes =
          List<VpnNodeInfo>.of(context.read<VpnController>().nodes);
      for (final VpnNodeInfo node in nodes) {
        if (!mounted) return;
        if (!node.online) continue;
        final PingSample sample = await _ping.probeHost(node.latencyHost);
        if (!mounted) return;
        setState(() => _samples[node.id] = sample);
      }
    } finally {
      _probing = false;
    }
  }

  Future<void> _refresh() async {
    await context.read<VpnController>().loadNodes();
    await _probeAll();
  }

  void _select(VpnController vpn, VpnNodeInfo node) {
    final bool wasConnected = vpn.isConnected || vpn.isTransitioning;
    vpn.selectNode(node);
    // While a tunnel is up the controller refuses the switch and posts a
    // notice; staying on this screen keeps that message visible.
    if (!wasConnected) widget.onDone?.call();
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
        return byLoad != 0
            ? byLoad
            : a.displayTitle.compareTo(b.displayTitle);
      });
    final List<VpnNodeInfo> others = vpn.nodes
        .where((VpnNodeInfo node) => !node.connectable)
        .toList()
      ..sort((VpnNodeInfo a, VpnNodeInfo b) =>
          a.displayTitle.compareTo(b.displayTitle));

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Row(
              children: <Widget>[
                if (widget.onDone != null)
                  CircleIconButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: widget.onDone!,
                    tooltip: 'Back',
                  ),
                if (widget.onDone != null) const SizedBox(width: 14),
                Text('Servers', style: text.headlineSmall),
                const Spacer(),
                CircleIconButton(
                  icon: Icons.refresh_rounded,
                  onTap: _refresh,
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
              onRefresh: _refresh,
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
                      message: 'No servers available right now. '
                          'Pull down to refresh.',
                      tone: GlukColors.violetLight,
                    ),
                  if (recommended.isNotEmpty) ...<Widget>[
                    const _SectionLabel(label: 'For You'),
                    const SizedBox(height: 10),
                    for (final VpnNodeInfo node in recommended)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _ServerTile(
                          node: node,
                          sample: _samples[node.id],
                          selected: vpn.selectedNode?.id == node.id,
                          onTap: () => _select(vpn, node),
                        ),
                      ),
                  ],
                  if (others.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    const _SectionLabel(label: 'Other Servers'),
                    const SizedBox(height: 10),
                    for (final VpnNodeInfo node in others)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _ServerTile(
                          node: node,
                          sample: _samples[node.id],
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

/// `.srv-row` - a fully rounded row: flag disc, place, signal bars, radio.
class _ServerTile extends StatelessWidget {
  const _ServerTile({
    required this.node,
    required this.sample,
    required this.selected,
    required this.onTap,
  });

  final VpnNodeInfo node;
  final PingSample? sample;
  final bool selected;
  final VoidCallback? onTap;

  /// City, region and live figures - all from the backend, never a node name.
  String get _details {
    if (!node.online) return 'Offline';
    final List<String> parts = <String>[node.displaySubtitle];
    final String region = node.region ?? '';
    if (region.isNotEmpty && region != node.displaySubtitle) parts.add(region);
    if (!node.connectable) {
      parts.add('unavailable');
    } else {
      parts.add('${node.loadPercent.round()}% load');
      final int? ms = sample?.milliseconds;
      if (ms != null) parts.add('$ms ms');
    }
    return parts.join('  \u00b7  ');
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final PingLevel level =
        node.online ? pingLevelFor(sample?.milliseconds) : PingLevel.unknown;

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
                      Flexible(
                        child: Text(
                          node.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: node.online
                              ? GlukColors.connected
                              : GlukColors.text2,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SignalBars(level: level),
            const SizedBox(width: 10),
            _Radio(selected: selected, enabled: node.connectable),
          ],
        ),
      ),
    );
  }
}

/// Latency as `///` - three leaning bars, lit according to the round-trip.
///
/// A level reads faster than a number, and the number is still in the row for
/// anyone who wants it.
class SignalBars extends StatelessWidget {
  const SignalBars({super.key, required this.level, this.showLabel = true});

  final PingLevel level;
  final bool showLabel;

  Color get _tone {
    switch (level) {
      case PingLevel.excellent:
        return GlukColors.connected;
      case PingLevel.medium:
        return GlukColors.violetLight;
      case PingLevel.low:
        return GlukColors.amber;
      case PingLevel.unknown:
        return GlukColors.text2;
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        CustomPaint(
          size: const Size(22, 14),
          painter: _SignalBarsPainter(bars: level.bars, tone: _tone),
        ),
        if (showLabel && level != PingLevel.unknown) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            level.label,
            style: text.bodySmall?.copyWith(fontSize: 9, color: _tone),
          ),
        ],
      ],
    );
  }
}

class _SignalBarsPainter extends CustomPainter {
  const _SignalBarsPainter({required this.bars, required this.tone});

  final int bars;
  final Color tone;

  @override
  void paint(Canvas canvas, Size size) {
    const int count = 3;
    const double lean = 3.4; // how far the top of each bar leans right
    final double width = 3.0;
    final double gap = (size.width - lean - count * width) / (count - 1);

    for (int i = 0; i < count; i++) {
      final double height = size.height * (0.45 + 0.275 * i);
      final double left = i * (width + gap);
      final double bottom = size.height;
      final Path bar = Path()
        ..moveTo(left, bottom)
        ..lineTo(left + lean, bottom - height)
        ..lineTo(left + lean + width, bottom - height)
        ..lineTo(left + width, bottom)
        ..close();
      canvas.drawPath(
        bar,
        Paint()
          ..color = i < bars ? tone : GlukColors.stroke
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(_SignalBarsPainter oldDelegate) =>
      oldDelegate.bars != bars || oldDelegate.tone != tone;
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
