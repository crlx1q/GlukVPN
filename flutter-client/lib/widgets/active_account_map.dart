import 'package:flutter/material.dart';
import '../models/account_insights.dart';
import '../services/api_client.dart';
import '../state/account_insights_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart';
import '../utils/geo.dart';
import 'dotted_world.dart';

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

/// The SAME button and sheet on Windows and Android. No secondary map exists here.
class AccountDevicesButton extends StatelessWidget {
  const AccountDevicesButton({super.key, required this.controller, required this.russian, this.onShowMap});
  final AccountInsightsController controller;
  final bool russian;
  final VoidCallback? onShowMap;
  @override Widget build(BuildContext context) => AnimatedBuilder(animation: controller, builder: (context, _) => TextButton.icon(
    style: TextButton.styleFrom(foregroundColor: GlukColors.violetLight, backgroundColor: GlukColors.cell.withOpacity(.94), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: GlukColors.violet.withOpacity(.3)))),
    icon: const Icon(Icons.devices, size: 20),
    label: Text('${russian ? 'Устройства' : 'Devices'} · ${controller.snapshot?.activeTunnels ?? '—'}'),
    onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, backgroundColor: GlukColors.cell,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (sheetContext) => SafeArea(child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheetContext).height * .8),
        child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
          Row(children: <Widget>[const Icon(Icons.devices, color: GlukColors.violetLight), const SizedBox(width: 10), Expanded(child: Text(russian ? 'Устройства онлайн' : 'Devices online', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))), IconButton(tooltip: russian ? 'Закрыть' : 'Close', onPressed: () => Navigator.pop(sheetContext), icon: const Icon(Icons.close))]),
          const SizedBox(height: 12),
          ActiveAccountMap(api: controller.api, controller: controller, russian: russian),
          if (onShowMap != null) Padding(padding: const EdgeInsets.only(top: 12), child: TextButton.icon(icon: const Icon(Icons.map_outlined), label: Text(russian ? 'Рассмотреть на фоне' : 'Inspect background map'), onPressed: () { Navigator.pop(sheetContext); onShowMap!(); })),
        ]))))),
  ));
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
    if(snapshot==null) return Padding(padding:const EdgeInsets.all(16),child:controller.loading ? const Center(child:CircularProgressIndicator()) : Column(mainAxisSize:MainAxisSize.min,children:[Text(ru?'Подключения сейчас недоступны':'Connections unavailable'),TextButton.icon(onPressed:controller.refresh,icon:const Icon(Icons.refresh),label:Text(ru?'Повторить':'Retry'))]));
    return Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:<Widget>[
      Text(ru?'${snapshot.activeTunnels} подключено · лимит устройств ${snapshot.maxDevices}':'${snapshot.activeTunnels} connected · device limit ${snapshot.maxDevices}',style:const TextStyle(fontSize:13,color:GlukColors.text2)),
      const SizedBox(height:12),
      if(snapshot.service.maintenance) Padding(padding:const EdgeInsets.only(bottom:12),child:Text(ru?'Сервис на обслуживании':'Service maintenance',style:const TextStyle(color:GlukColors.amber))),
      if(snapshot.devices.isEmpty) Padding(padding:const EdgeInsets.all(24),child:Text(ru?'Нет активных подключений':'No active connections')),
      for(final d in snapshot.devices) Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:GlukColors.violet.withOpacity(.07),borderRadius:BorderRadius.circular(18),border:Border.all(color:GlukColors.violet.withOpacity(.2))),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
        Container(width:44,height:44,decoration:BoxDecoration(color:GlukColors.violet.withOpacity(.14),borderRadius:BorderRadius.circular(12)),child:Icon(accountDeviceIcon(d.platform),size:24,color:GlukColors.violetLight)),
        const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:<Widget>[
          Text(d.deviceName,style:const TextStyle(fontSize:15,fontWeight:FontWeight.w700)),
          if(d.isCurrent) Text(ru?'Это устройство':'This device',style:const TextStyle(fontSize:11,color:GlukColors.violetLight)),
          const SizedBox(height:6),
          Text('${d.platform} · ${d.status=='ACTIVE'?(ru?'Подключено':'Connected'):(ru?'Подключение…':'Connecting…')}',style:TextStyle(fontSize:12,color:d.status=='ACTIVE'?GlukColors.connected:GlukColors.amber)),
          const SizedBox(height:4),Text('→ ${d.node.city ?? d.node.displayTitle} · ${formatDuration(Duration(seconds:d.durationSec))}',style:const TextStyle(fontSize:13)),
          const SizedBox(height:4),Text(d.origin?.valid==true ? '${d.origin!.country??d.origin!.countryCode??''} · ${d.origin!.source=='device-estimate'?(ru?'≈ оценка региона устройства':'≈ device region estimate'):(ru?'≈ страна по IP':'≈ IP country')}' : (ru?'Регион ещё не определён':'Region not available yet'),style:const TextStyle(fontSize:11,color:GlukColors.text2)),
        ])),
      ])),
    ]);
  }
}
