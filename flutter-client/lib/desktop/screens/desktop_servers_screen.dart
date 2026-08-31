import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../logic/node_selector.dart';
import '../state/desktop_vpn_controller.dart';
import '../widgets/server_row.dart';

/// Server selector (requirement 8).
///
/// Free accounts see Auto only; paid accounts get the full list. Internal
/// nodes are filtered out upstream by [visibleNodes], so nothing named
/// "beta-01" or "test-01" can ever reach this widget in a production build.
class DesktopServersScreen extends StatefulWidget {
  const DesktopServersScreen({
    super.key,
    required this.vpn,
    required this.strings,
  });

  final DesktopVpnController vpn;
  final DesktopStrings strings;

  @override
  State<DesktopServersScreen> createState() => _DesktopServersScreenState();
}

class _DesktopServersScreenState extends State<DesktopServersScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.strings;
    final vpn = widget.vpn;
    final paid = manualSelectionAllowed(vpn.subscription);

    final all = vpn.userVisibleNodes;
    final filtered = _query.isEmpty
        ? all
        : all.where((VpnNodeInfo n) {
            final needle = _query.toLowerCase();
            return publicNodeTitle(n).toLowerCase().contains(needle) ||
                (publicNodeSubtitle(n) ?? '')
                    .toLowerCase()
                    .contains(needle);
          }).toList();

    return Padding(
      padding: const EdgeInsets.all(GlukSizes.pagePadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                s.servers,
                style: const TextStyle(
                  color: GlukColors.text0,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${filtered.length}',
                style: const TextStyle(
                  color: GlukColors.text2,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              CircleIconButton(
                icon: Icons.refresh_rounded,
                tooltip: s.refresh,
                onTap: () {
                  vpn.retryNodes();
                  vpn.measureNodePings();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Never leave the user staring at an empty list without a reason.
          if (vpn.nodesError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: InlineNotice(
                message: vpn.nodesError!,
                tone: NoticeTone.warning,
              ),
            ),

          // Auto / Best server is always first and always available.
          _AutoCard(
            strings: s,
            selected: vpn.autoSelectionEnabled,
            resolved: vpn.autoSelection?.node,
            onTap: () => vpn.setAutoSelection(true),
          ),

          if (!paid) ...<Widget>[
            const SizedBox(height: 12),
            InlineNotice(message: s.manualLocked, tone: NoticeTone.info),
          ],

          const SizedBox(height: 16),

          if (all.length > 6)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _search,
                onChanged: (String value) =>
                    setState(() => _query = value.trim()),
                style: const TextStyle(
                  color: GlukColors.text0,
                  fontSize: 13,
                ),
                cursorColor: GlukColors.violetLight,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: s.servers,
                  hintStyle: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 17,
                    color: GlukColors.text2,
                  ),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.04),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: GlukColors.stroke),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: GlukColors.stroke),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: GlukColors.violet),
                  ),
                ),
              ),
            ),

          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          vpn.nodesLoading
                              ? Icons.hourglass_empty_rounded
                              : Icons.cloud_off_rounded,
                          size: 26,
                          color: GlukColors.text2,
                        ),
                        const SizedBox(height: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Text(
                            vpn.nodesError ?? s.noServers,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: GlukColors.text1,
                              fontSize: 13,
                              height: 1.35,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: 220,
                          child: PrimaryPillButton(
                            label: s.refresh,
                            icon: Icons.refresh_rounded,
                            busy: vpn.nodesLoading,
                            onPressed: () => vpn.retryNodes(),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: filtered.length,
                    itemBuilder: (BuildContext context, int index) {
                      final node = filtered[index];
                      return ServerRow(
                        node: node,
                        selected: !vpn.autoSelectionEnabled &&
                            vpn.selectedNode?.id == node.id,
                        pingMs: vpn.pings[node.id],
                        locked: !paid,
                        loadLabel: s.load,
                        offlineLabel: s.offline,
                        onTap: paid ? () => vpn.switchNode(node) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _AutoCard extends StatelessWidget {
  const _AutoCard({
    required this.strings,
    required this.selected,
    required this.onTap,
    this.resolved,
  });

  final DesktopStrings strings;
  final bool selected;
  final VoidCallback onTap;
  final VpnNodeInfo? resolved;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: GlukSizes.cellRadius,
      onTap: onTap,
      color: selected ? GlukColors.violet.withOpacity(0.12) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: <Widget>[
          Container(
            width: GlukSizes.flagCircle,
            height: GlukSizes.flagCircle,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: GlukGradients.blobInner,
            ),
            child: const Icon(
              Icons.bolt_rounded,
              size: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  strings.autoBestServer,
                  style: const TextStyle(
                    color: GlukColors.text0,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  resolved == null
                      ? strings.autoDescription
                      : '${strings.autoDescription} · '
                          '${publicNodeTitle(resolved!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GlukColors.text2,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (selected)
            const Icon(
              Icons.check_circle_rounded,
              size: 17,
              color: GlukColors.violetLight,
            ),
        ],
      ),
    );
  }
}
