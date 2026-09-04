import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../services/ping_service.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/geo.dart';
import '../utils/geo_dictionary.dart';
import '../utils/signal.dart';
import '../widgets/glass.dart';
import '../widgets/signal_bars.dart';
import '../widgets/skeleton.dart';

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
    final AppStrings s = context.strings;
    final VpnController vpn = context.watch<VpnController>();
    final MotionController motion = context.watch<MotionController>();
    final TextTheme text = Theme.of(context).textTheme;
    final bool loadingFirstTime = vpn.nodes.isEmpty && vpn.loadingNodes;

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
                    tooltip: s.back,
                  ),
                if (widget.onDone != null) const SizedBox(width: 14),
                Text(s.servers, style: text.headlineSmall),
                const Spacer(),
                CircleIconButton(
                  icon: Icons.refresh_rounded,
                  onTap: _refresh,
                  tooltip: s.refresh,
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
                  // First load: three rows in the shape of a server row, so
                  // the list arrives into a layout that already exists instead
                  // of replacing a spinner in the middle of nowhere.
                  if (loadingFirstTime) ...<Widget>[
                    _SectionLabel(label: s.forYou),
                    const SizedBox(height: 10),
                    for (int i = 0; i < 3; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 9),
                        child: _ServerTileSkeleton(
                          animate: !motion.reduceMotion,
                        ),
                      ),
                  ],
                  if (vpn.nodes.isEmpty && !vpn.loadingNodes)
                    InlineNotice(
                      message: s.noServersPullToRefresh,
                      tone: GlukColors.violetLight,
                    ),
                  if (recommended.isNotEmpty) ...<Widget>[
                    _SectionLabel(label: s.forYou),
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
                    _SectionLabel(label: s.otherServers),
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
  String _details(AppStrings s) {
    if (!node.online) return s.offline;
    final String city = localizeCity(node.city, russian: s.isRussian);
    final List<String> parts = <String>[
      city.isNotEmpty ? city : node.displaySubtitle,
    ];
    final String region = node.region ?? '';
    if (region.isNotEmpty && region != node.displaySubtitle) parts.add(region);
    if (!node.connectable) {
      parts.add(s.unavailable);
    } else {
      parts.add(s.loadPercent(node.loadPercent.round()));
      final int? ms = sample?.milliseconds;
      if (ms != null) parts.add('$ms ${s.ms}');
    }
    return parts.join('  \u00b7  ');
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    // Three bars, computed from the node's own numbers: whether it is online,
    // how loaded it says it is, and the round trip this phone just measured.
    final SignalStrength signal = signalStrengthFor(
      online: node.online,
      available: node.connectable,
      pingMs: sample?.milliseconds,
      loadPercent: node.loadPercent.toDouble(),
    );

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
                          // ROUND 5: "Frankfurt, Германия" - city first, then
                          // country, translated through the shared dictionary
                          // that mirrors extension/lib/geo.js, so the phone and
                          // the PC name the same server identically.
                          formatNodeLocation(
                            city: node.city,
                            countryCode: node.countryCode,
                            countryName: node.country,
                            region: node.region,
                            // Was left at the dictionary's default (Russian),
                            // so an English interface still read "Германия".
                            russian: s.isRussian,
                          ),
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
                    _details(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SignalBars(strength: signal),
            const SizedBox(width: 10),
            _Radio(selected: selected, enabled: node.connectable),
          ],
        ),
      ),
    );
  }
}

/// A server row with nothing in it yet: the same disc, two lines, bars and
/// radio as [_ServerTile], drawn as shimmering bars. Sized from the same text
/// styles, so the real rows land exactly where these were.
class _ServerTileSkeleton extends StatelessWidget {
  const _ServerTileSkeleton({required this.animate});

  final bool animate;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
      child: Row(
        children: <Widget>[
          SkeletonBox(
            width: GlukSizes.flagCircle,
            height: GlukSizes.flagCircle,
            radius: GlukSizes.flagCircle / 2,
            animate: animate,
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SkeletonText(
                  characters: 18,
                  style: text.titleMedium,
                  animate: animate,
                ),
                const SizedBox(height: 2),
                SkeletonText(
                  characters: 26,
                  style: text.bodySmall?.copyWith(fontSize: 10.5),
                  animate: animate,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Stand-ins for the signal bars and the radio.
          SkeletonBox(width: 18, height: 12, radius: 3, animate: animate),
          const SizedBox(width: 10),
          SkeletonBox(
            width: GlukSizes.radio,
            height: GlukSizes.radio,
            radius: GlukSizes.radio / 2,
            animate: animate,
          ),
        ],
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
