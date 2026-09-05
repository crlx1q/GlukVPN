import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../models/account_insights.dart';
import '../services/api_client.dart';
import '../state/account_insights_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';
import '../utils/geo.dart';
import 'dotted_world.dart';

// Единая палитра панели устройств. Те же значения продублированы на сайте
// (`site/assets/css/dashboard.css`) и в расширении (`extension/ui/theme.css`),
// чтобы четыре поверхности читались как одно приложение.
const Color _chipBg = Color(0xE61A1428);
const Color _panelBg = Color(0xF717122A);
const Color _panelBorder = Color(0x33C4B5FD);
const Color _routeText = Color(0xFFBFB4D4);
const Color _countText = Color(0xFFEFE7FF);
const double _panelWidth = 320;

IconData accountDeviceIcon(String platform) {
  final p = platform.toLowerCase();
  if (p.contains('android') || p.contains('ios') || p.contains('phone')) return Icons.smartphone;
  if (p.contains('chrome') || p.contains('browser') || p.contains('extension')) return Icons.web;
  return Icons.computer;
}

List<ConnectionArc> accountMapArcs(ActiveMapSnapshot? snapshot) => <ConnectionArc>[
  for (final d in snapshot?.devices ?? <ActiveTunnelDevice>[])
    if (d.status == 'ACTIVE' && d.origin?.valid == true && d.node.location != null && d.node.location!.lat.isFinite && d.node.location!.lon.isFinite && d.node.location!.lat.abs() <= 90 && d.node.location!.lon.abs() <= 180)
      AccountConnectionArc(from: projectLatLon(d.origin!.lat, d.origin!.lon), to: projectLatLon(d.node.location!.lat, d.node.location!.lon), isCurrent: d.isCurrent,
        label: '${d.deviceName} · ${d.platform}\n→ ${d.node.displayTitle}\n${d.origin!.source == 'device-estimate' ? '≈ device region estimate' : '≈ IP country'}', platform: d.platform, serverLabel: d.node.displayTitle),
];

/// Чип «Устройства · N» и привязанная к нему выпадающая панель. Один и тот же
/// виджет на Windows и Android, тот же макет повторён на сайте и в расширении.
///
/// Раньше здесь открывался `showModalBottomSheet`: он перекрывал карточку
/// сервера и на Windows выглядел как чужеродный лист снизу. Теперь это
/// полупрозрачная панель под чипом с одинаковым поведением на всех платформах.
class AccountDevicesButton extends StatefulWidget {
  const AccountDevicesButton({super.key, required this.controller, required this.russian});
  final AccountInsightsController controller;
  final bool russian;
  @override State<AccountDevicesButton> createState() => _AccountDevicesButtonState();
}

class _AccountDevicesButtonState extends State<AccountDevicesButton> {
  final GlobalKey _chipKey = GlobalKey();
  bool _open = false;

  Future<void> _toggle() async {
    final chip = _chipKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (chip == null || overlay == null || !chip.hasSize) return;
    final anchor = chip.localToGlobal(chip.size.bottomRight(Offset.zero), ancestor: overlay);
    final screen = overlay.size;
    setState(() => _open = true);
    await showGeneralDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      barrierDismissible: true,
      barrierLabel: widget.russian ? 'Закрыть' : 'Close',
      transitionDuration: const Duration(milliseconds: 170),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (dialogContext, animation, _, __) {
        final curve = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return Stack(children: <Widget>[
          Positioned(
            top: anchor.dy + 10,
            right: (screen.width - anchor.dx).clamp(12.0, screen.width),
            child: FadeTransition(
              opacity: curve,
              child: ScaleTransition(
                alignment: Alignment.topRight,
                scale: Tween<double>(begin: .96, end: 1).animate(curve),
                child: _AccountDevicesPanel(
                  controller: widget.controller,
                  russian: widget.russian,
                  width: (screen.width - 24).clamp(0.0, _panelWidth),
                  maxHeight: (screen.height - anchor.dy - 44).clamp(180.0, 420.0),
                  onClose: () => Navigator.pop(dialogContext),
                ),
              ),
            ),
          ),
        ]);
      },
    );
    if (mounted) setState(() => _open = false);
  }

  @override Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final ru = widget.russian;
      return Material(
        key: _chipKey,
        color: _chipBg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: GlukColors.violet.withOpacity(_open ? .62 : .36)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
              const Icon(Icons.devices, size: 18, color: GlukColors.violetLight),
              const SizedBox(width: 8),
              Text(ru ? 'Устройства' : 'Devices', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: GlukColors.violetLight)),
              const SizedBox(width: 8),
              Container(
                constraints: const BoxConstraints(minWidth: 20),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: GlukColors.violet.withOpacity(.24), borderRadius: BorderRadius.circular(8)),
                child: Text('${widget.controller.snapshot?.activeTunnels ?? '—'}', textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: _countText)),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _open ? .5 : 0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: GlukColors.violetLight),
              ),
            ]),
          ),
        ),
      );
    },
  );
}

class _AccountDevicesPanel extends StatelessWidget {
  const _AccountDevicesPanel({required this.controller, required this.russian, required this.width, required this.maxHeight, required this.onClose});
  final AccountInsightsController controller;
  final bool russian;
  final double width, maxHeight;
  final VoidCallback onClose;

  @override Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: Container(
        width: width,
        constraints: BoxConstraints(maxHeight: maxHeight),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: _panelBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _panelBorder),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x9E000000), blurRadius: 54, offset: Offset(0, 22))],
        ),
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Row(children: <Widget>[
              Expanded(child: Text(russian ? 'Устройства онлайн' : 'Devices online',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: GlukColors.text0))),
              IconButton(
                onPressed: onClose,
                tooltip: russian ? 'Закрыть' : 'Close',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Icons.close_rounded, color: GlukColors.text1),
              ),
            ]),
            Flexible(child: ActiveAccountMap(api: controller.api, controller: controller, russian: russian, compact: true)),
          ]),
        ),
      ),
    ),
  );
}

/// Плитка устройства: глиф в сиреневом квадрате, имя, «платформа · время»,
/// маршрут, зелёная точка и шеврон. Ровно то же самое в расширении и на сайте.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.russian});
  final ActiveTunnelDevice device;
  final bool russian;

  @override Widget build(BuildContext context) {
    final live = device.status == 'ACTIVE';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: GlukColors.violet.withOpacity(.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: GlukColors.violet.withOpacity(.18)),
      ),
      child: Row(children: <Widget>[
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: GlukColors.violet.withOpacity(.2), borderRadius: BorderRadius.circular(14)),
          child: Icon(accountDeviceIcon(device.platform), size: 22, color: GlukColors.violetLight),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(device.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: GlukColors.text0)),
          const SizedBox(height: 2),
          Text('${device.platform} · ${formatDuration(Duration(seconds: device.durationSec))}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: GlukColors.text1)),
          const SizedBox(height: 2),
          Text('→ ${device.node.city ?? device.node.displayTitle}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: _routeText)),
          if (device.isCurrent) Padding(padding: const EdgeInsets.only(top: 4), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: GlukColors.violetLight.withOpacity(.15), borderRadius: BorderRadius.circular(999)),
            child: Text(russian ? 'Это устройство' : 'This device',
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: GlukColors.violetLight)),
          )),
        ])),
        const SizedBox(width: 10),
        Tooltip(
          message: live ? (russian ? 'Подключено' : 'Connected') : (russian ? 'Подключение…' : 'Connecting…'),
          child: Container(width: 8, height: 8, decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: live ? GlukColors.connected : GlukColors.text2,
            boxShadow: live ? <BoxShadow>[BoxShadow(color: GlukColors.connected.withOpacity(.85), blurRadius: 10)] : null,
          )),
        ),
        const SizedBox(width: 9),
        const Icon(Icons.chevron_right_rounded, size: 18, color: GlukColors.text2),
      ]),
    );
  }
}

/// Compatibility name; this widget is deliberately a list only, even for old callers.
class ActiveAccountMap extends StatefulWidget {
  const ActiveAccountMap({super.key, required this.api, this.controller, this.compact = false, this.russian = false, this.showMap = false, this.reduceMotion = false, this.onServiceChanged});
  final ApiClient api;
  final AccountInsightsController? controller;
  final bool compact, russian, showMap, reduceMotion;
  final ValueChanged<ServiceStatus>? onServiceChanged;
  @override State<ActiveAccountMap> createState() => _ActiveAccountMapState();
}
class _ActiveAccountMapState extends State<ActiveAccountMap> with WidgetsBindingObserver {
  late AccountInsightsController controller;
  bool get _owns => widget.controller == null;
  @override void initState() { super.initState(); _attach(); WidgetsBinding.instance.addObserver(this); }
  void _attach() { controller = widget.controller ?? AccountInsightsController(widget.api); controller.addListener(_changed); if (_owns) controller.setVisible(true); }
  void _changed() { if (!mounted) return; final s=controller.snapshot; if(s!=null)widget.onServiceChanged?.call(s.service); setState(() {}); }
  @override void didUpdateWidget(covariant ActiveAccountMap old) { super.didUpdateWidget(old); if(old.api!=widget.api||old.controller!=widget.controller){controller.removeListener(_changed);if(old.controller==null)controller.dispose();_attach();} }
  @override void didChangeAppLifecycleState(AppLifecycleState state) { if(_owns)controller.setVisible(state==AppLifecycleState.resumed); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this);controller.removeListener(_changed);if(_owns)controller.dispose();super.dispose(); }
  @override Widget build(BuildContext context) {
    final snapshot=controller.snapshot, ru=widget.russian;
    if(snapshot==null) return Padding(padding:const EdgeInsets.all(16),child:controller.loading
      ? const Center(child:SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2,color:GlukColors.violetLight)))
      : Column(mainAxisSize:MainAxisSize.min,children:<Widget>[
          Text(ru?'Подключения сейчас недоступны':'Connections unavailable',textAlign:TextAlign.center,style:const TextStyle(fontSize:12,color:GlukColors.text1)),
          TextButton.icon(onPressed:controller.refresh,icon:const Icon(Icons.refresh,size:16),label:Text(ru?'Повторить':'Retry'),style:TextButton.styleFrom(foregroundColor:GlukColors.violetLight)),
        ]));
    return ListView(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: widget.compact ? null : const NeverScrollableScrollPhysics(),
      children: <Widget>[
        Padding(padding:const EdgeInsets.only(bottom:11),child:Text(
          ru?'${snapshot.activeTunnels} подключено · лимит устройств ${snapshot.maxDevices}':'${snapshot.activeTunnels} connected · device limit ${snapshot.maxDevices}',
          style:const TextStyle(fontSize:11.5,color:GlukColors.text1))),
        if(snapshot.service.maintenance) Padding(padding:const EdgeInsets.only(bottom:11),child:Text(
          ru?'Сервис на обслуживании':'Service maintenance',style:const TextStyle(fontSize:11.5,color:GlukColors.amber))),
        if(snapshot.devices.isEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:20),child:Text(
          ru?'Нет активных подключений':'No active connections',textAlign:TextAlign.center,style:const TextStyle(fontSize:11.5,color:GlukColors.text1))),
        for(final d in snapshot.devices) _DeviceRow(device:d,russian:ru),
      ],
    );
  }
}
