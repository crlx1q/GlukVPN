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
  void initState() {
    super.initState();
    // Мини-пинг на заходе в список: до этого цифры появлялись только
    // после обновления узлов. Кулдаун внутри контроллера, поэтому
    // десять заходов подряд — ноль лишних замеров.
    widget.vpn.measureNodePings();
  }

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
            return publicNodeLocation(n, russian: s.isRussian)
                    .toLowerCase()
                    .contains(needle) ||
                publicNodeTitle(n).toLowerCase().contains(needle) ||
                (publicNodeSubtitle(n) ?? '')
                    .toLowerCase()
                    .contains(needle);
          }).toList();

    // Порядок и заголовки — как на телефоне: доступные сверху по
    // нагрузке под «Для вас», недоступные — серыми вниз под
    // «Другие серверы». До этого список шёл в порядке контроллера,
    // и офлайн-узел мог стоять первой строкой.
    String label(VpnNodeInfo node) =>
        publicNodeLocation(node, russian: s.isRussian);
    final List<VpnNodeInfo> recommended = filtered
        .where((VpnNodeInfo n) => n.connectable)
        .toList()
      ..sort((VpnNodeInfo a, VpnNodeInfo b) {
        final int byLoad = a.loadPercent.compareTo(b.loadPercent);
        return byLoad != 0 ? byLoad : label(a).compareTo(label(b));
      });
    final List<VpnNodeInfo> others = filtered
        .where((VpnNodeInfo n) => !n.connectable)
        .toList()
      ..sort((VpnNodeInfo a, VpnNodeInfo b) =>
          label(a).compareTo(label(b)));
    // Плоский список для ListView: заголовок — String, строка — узел.
    final List<Object> entries = <Object>[
      if (recommended.isNotEmpty) s.forYou,
      ...recommended,
      if (others.isNotEmpty) s.otherServers,
      ...others,
    ];

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
                  // Ручное обновление — единственный способ обойти часовой
                  // кулдаун.
                  vpn.measureNodePings(force: true);
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
                    itemCount: entries.length,
                    itemBuilder: (BuildContext context, int index) {
                      final Object entry = entries[index];
                      if (entry is String) {
                        return _SectionLabel(label: entry, first: index == 0);
                      }
                      final VpnNodeInfo node = entry as VpnNodeInfo;
                      return ServerRow(
                        node: node,
                        selected: !vpn.autoSelectionEnabled &&
                            vpn.selectedNode?.id == node.id,
                        pingMs: vpn.pings[node.id],
                        unreachable: vpn.nodeUnreachable(node.id),
                        locked: !paid,
                        loadLabel: s.load,
                        offlineLabel: s.offline,
                        // ROUND 7: the row localises its own geography label,
                        // so it has to know which language the shell is in.
                        russian: s.isRussian,
                        // Офлайн-узел не выбирается — как на телефоне.
                        onTap: paid && node.connectable
                            ? () => vpn.switchNode(node)
                            : null,
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
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // Плоский кружок вместо градиента и глобус вместо молнии —
              // один знак «Авто» на телефоне, ПК и в расширении. Градиент
              // повторял вид выбранного элемента и читался как «включено».
              color: GlukColors.violet.withOpacity(0.18),
              border: Border.all(
                color: GlukColors.violetLight.withOpacity(0.30),
              ),
            ),
            child: const Icon(
              Icons.public_rounded,
              size: 16,
              color: GlukColors.violetLight,
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
                          '${publicNodeLocation(resolved!, russian: strings.isRussian)}',
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

/// Заголовок группы в списке серверов.
///
/// Тот же элемент, что `_SectionLabel` на телефоне и `.srv-section`
/// в расширении: капсом, серый, без рамки.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label, this.first = false});

  final String label;

  /// У самого верхнего заголовка нет отступа сверху: над ним уже
  /// стоит поле поиска или карточка «Авто».
  final bool first;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : 10, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: GlukColors.text2,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}
