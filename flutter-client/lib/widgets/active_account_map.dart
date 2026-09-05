import 'package:flutter/material.dart';
import '../models/account_insights.dart';
import '../services/api_client.dart';
import '../state/account_insights_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';
import '../utils/geo.dart';
import 'dotted_world.dart';

bool _valid(double lat, double lon) => lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180;
List<ConnectionArc> accountMapArcs(ActiveMapSnapshot? snapshot) => <ConnectionArc>[
  for (final d in snapshot?.devices ?? <ActiveTunnelDevice>[])
    if (d.status == 'ACTIVE' && d.origin != null && d.origin!.valid && d.node.location != null && _valid(d.node.location!.lat, d.node.location!.lon))
      AccountConnectionArc(from: projectLatLon(d.origin!.lat, d.origin!.lon), to: projectLatLon(d.node.location!.lat, d.node.location!.lon), label: '${d.deviceName} · ${d.platform}\n→ ${d.node.displayTitle}\n${formatDuration(Duration(seconds: d.durationSec))}', platform: d.platform, serverLabel: d.node.displayTitle),
];

/// Reuses the production world projection; missing geography is never invented.
class ActiveAccountMap extends StatefulWidget {
  const ActiveAccountMap({super.key, required this.api, this.controller, this.compact = false, this.russian = false, this.showMap = true, this.reduceMotion = false, this.onServiceChanged});
  final ApiClient api;
  final AccountInsightsController? controller;
  final bool compact, russian, showMap, reduceMotion;
  final ValueChanged<ServiceStatus>? onServiceChanged;
  @override State<ActiveAccountMap> createState() => _ActiveAccountMapState();
}
class _ActiveAccountMapState extends State<ActiveAccountMap> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late AccountInsightsController controller;
  late final AnimationController _flow = AnimationController(vsync: this, duration: const Duration(seconds: 6));
  bool _resumed = true;
  bool get _owns => widget.controller == null;
  @override void initState() {
    super.initState(); _attach(); WidgetsBinding.instance.addObserver(this);
  }
  void _attach() {
    controller = widget.controller ?? AccountInsightsController(widget.api);
    controller.addListener(_changed);
    if (_owns) controller.setVisible(true);
  }
  void _changed() {
    if (!mounted) return;
    final snapshot = controller.snapshot;
    if (snapshot != null && controller.error == null) widget.onServiceChanged?.call(snapshot.service);
    setState(() {});
  }
  @override void didChangeDependencies() { super.didChangeDependencies(); _motion(); }
  void _motion() {
    if (_resumed && widget.showMap && !widget.reduceMotion && !MediaQuery.disableAnimationsOf(context) && TickerMode.of(context)) {
      if (!_flow.isAnimating) _flow.repeat();
    } else { _flow.stop(); }
  }
  @override void didUpdateWidget(covariant ActiveAccountMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.controller != widget.controller) {
      controller.removeListener(_changed);
      if (oldWidget.controller == null) controller.dispose();
      _attach();
    }
    _motion();
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (_owns) controller.setVisible(_resumed);
    _motion();
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this); _flow.dispose();
    controller.removeListener(_changed); if (_owns) controller.dispose(); super.dispose();
  }
  IconData _icon(String platform) {
    final p = platform.toLowerCase();
    if (p.contains('android') || p.contains('ios')) return Icons.smartphone_rounded;
    if (p.contains('chrome') || p.contains('browser') || p.contains('extension')) return Icons.web_rounded;
    return Icons.computer_rounded;
  }
  @override Widget build(BuildContext context) {
    final s = controller.snapshot, ru = widget.russian;
    Widget body;
    if (controller.loading && s == null) {
      body = Semantics(label: ru ? 'Загрузка карты аккаунта' : 'Loading account map', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        for (final width in <double>[.8, .55, .7]) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: FractionallySizedBox(widthFactor: width, alignment: Alignment.centerLeft, child: Container(height: 12, decoration: BoxDecoration(color: GlukColors.violet.withOpacity(.18), borderRadius: BorderRadius.circular(6))))),
      ]));
    } else if (s == null) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(ru ? 'Состояние подключений сейчас недоступно' : 'Connection state is currently unavailable', style: const TextStyle(fontSize: 11, color: GlukColors.text2)),
        TextButton.icon(onPressed: controller.refresh, icon: const Icon(Icons.refresh, size: 16), label: Text(ru ? 'Повторить' : 'Retry')),
      ]);
    } else {
      final arcs = accountMapArcs(s);
      final missing = s.devices.where((d) => d.origin == null || !d.origin!.valid || d.node.location == null || !_valid(d.node.location!.lat, d.node.location!.lon)).length;
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: <Widget>[
        Row(children: <Widget>[
          Icon(s.service.maintenance ? Icons.build_circle_outlined : Icons.hub_outlined, size: 16, color: s.service.maintenance ? GlukColors.amber : GlukColors.connected),
          const SizedBox(width: 7),
          Expanded(child: Text(ru ? 'Подключения аккаунта' : 'Account connections', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
          Text('${s.activeTunnels}/${s.maxDevices}', style: const TextStyle(fontSize: 12, color: GlukColors.text2)),
        ]),
        if (s.service.maintenance) Padding(padding: const EdgeInsets.only(top: 7), child: Text(ru ? 'Сервис на техническом обслуживании. Скоро вернемся' : 'The service is under maintenance. We will be back soon.', style: const TextStyle(fontSize: 11, color: GlukColors.amber))),
        if (widget.showMap) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: SizedBox(height: widget.compact ? 106 : 170, child: AnimatedBuilder(animation: _flow, builder: (context, _) => DottedWorld(accountArcs: arcs, arcPhase: _flow.value, pulse: _flow.value, dotOpacity: .6, connected: s.activeTunnels > 0)))),
        if (s.devices.isEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Text(ru ? 'Нет активных туннелей' : 'No active tunnels', style: const TextStyle(color: GlukColors.text2, fontSize: 11)))
        else Padding(padding: const EdgeInsets.only(top: 7), child: Wrap(spacing: 6, runSpacing: 5, children: s.devices.map((d) {
          final server = d.node.city?.isNotEmpty == true ? d.node.city! : d.node.displayTitle;
          final current = d.isCurrent ? (ru ? ' · Это устройство' : ' · This device') : '';
          final geo = d.origin?.valid == true ? '${d.origin!.country ?? d.origin!.countryCode ?? ''} · ${ru ? 'примерно по IP' : 'approximate IP location'}' : (ru ? 'Геопозиция неизвестна' : 'Location unavailable');
          return Tooltip(message: '${d.deviceName}$current\n${d.platform} → $server\n$geo\n${formatDuration(Duration(seconds: d.durationSec))}', child: Chip(visualDensity: VisualDensity.compact, avatar: Icon(_icon(d.platform), size: 14), label: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 120), child: Text(d.deviceName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)))));
        }).toList())),
        if (missing > 0) Padding(padding: const EdgeInsets.only(top: 5), child: Text(ru ? 'Координаты неизвестны для $missing подключений; они учтены в счётчике.' : 'Location unavailable for $missing connections; they are still counted.', style: const TextStyle(fontSize: 10, color: GlukColors.text2))),
        if (s.truncated) Text(ru ? 'Показаны 5 последних подключений' : 'Showing the latest 5 connections', style: const TextStyle(fontSize: 10, color: GlukColors.text2)),
      ]);
    }
    return Container(padding: EdgeInsets.all(widget.compact ? 9 : 12), decoration: BoxDecoration(color: GlukColors.cell.withOpacity(.9), borderRadius: BorderRadius.circular(14), border: Border.all(color: GlukColors.violet.withOpacity(.25))), child: body);
  }
}
