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
            return n.displayTitle.toLowerCase().contains(needle) ||
                n.displaySubtitle.toLowerCase().contains(needle);
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
                  vpn.refreshNodes();
                  vpn.measureNodePings();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),

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
                    child: Text(
                      s.noServers,
                      style: const TextStyle(
                        color: GlukColors.text2,
                        fontSize: 13,
                      ),
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
      color: selected ? GlukColors.violet.withOpacity(0.12) : null,
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
                          '${resolved!.displayTitle}',
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
