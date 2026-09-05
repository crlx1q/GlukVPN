import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../models/account_insights.dart';
import '../models/models.dart';
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

// ЭТАП 2: панель стала уже и плотнее (было 320/13/44), а чип — только значок.
const double _panelWidth = 300;
const double _chipSize = 40;

IconData accountDeviceIcon(String platform) {
  final p = platform.toLowerCase();
  if (p.contains('android') || p.contains('ios') || p.contains('phone')) return Icons.smartphone;
  if (p.contains('chrome') || p.contains('browser') || p.contains('extension')) return Icons.web;
  return Icons.computer;
}

/// Ключ точки на карте с точностью до десятой доли карты: два устройства из
/// одного города дают один и тот же ключ, поэтому их можно сгруппировать в
/// один маркер с цифрой вместо кучи наложенных точек.
String _spotKey(double x, double y) => '${(x * 10).round()}:${(y * 10).round()}';

bool _placed(GeoPoint? p) => p != null && p.valid;

bool _placedNode(NodeLocation? p) =>
    p != null && p.lat.isFinite && p.lon.isFinite && p.lat.abs() <= 90 && p.lon.abs() <= 180;

/// Нитки соединений для карты.
///
/// ЭТАП 2 — так же, как это работало в старом клиенте на Windows:
///  • одна нитка на пару «точка устройства → сервер». Три устройства в одном
///    городе на одном сервере рисуют ОДНУ нитку, а не три наложенные;
///  • если второе устройство из той же точки ушло на другой сервер — это
///    вторая пара, значит вторая нитка;
///  • `spotCount` — сколько всего устройств стоит в этой точке. Именно эта
///    цифра рисуется бейджем на маркере.
List<ConnectionArc> accountMapArcs(ActiveMapSnapshot? snapshot) {
  final live = <ActiveTunnelDevice>[
    for (final d in snapshot?.devices ?? <ActiveTunnelDevice>[])
      if (d.status == 'ACTIVE' && _placed(d.origin) && _placedNode(d.node.location)) d,
  ];

  // Сколько устройств стоит в каждой точке — для бейджа с цифрой.
  final spots = <String, int>{};
  for (final d in live) {
    final from = projectLatLon(d.origin!.lat, d.origin!.lon);
    final key = _spotKey(from.x, from.y);
    spots[key] = (spots[key] ?? 0) + 1;
  }

  // Группировка «точка + сервер»: текущее устройство побеждает при выборе
  // глифа, чтобы на своём телефоне ты видел именно свою иконку.
  final pairs = <String, ActiveTunnelDevice>{};
  final order = <String>[];
  for (final d in live) {
    final from = projectLatLon(d.origin!.lat, d.origin!.lon);
    final to = projectLatLon(d.node.location!.lat, d.node.location!.lon);
    final key = '${_spotKey(from.x, from.y)}>${_spotKey(to.x, to.y)}';
    final kept = pairs[key];
    if (kept == null) {
      pairs[key] = d;
      order.add(key);
    } else if (d.isCurrent && !kept.isCurrent) {
      pairs[key] = d;
    }
  }

  return <ConnectionArc>[
    for (final key in order)
      if (pairs[key] != null)
        (() {
          final d = pairs[key]!;
          final from = projectLatLon(d.origin!.lat, d.origin!.lon);
          return AccountConnectionArc(
            from: from,
            to: projectLatLon(d.node.location!.lat, d.node.location!.lon),
            isCurrent: pairs[key]!.isCurrent,
            spotCount: spots[_spotKey(from.x, from.y)] ?? 1,
            label: '${d.deviceName} · ${d.platform}\n→ ${d.node.displayTitle}\n'
                '${d.origin!.source == 'device-estimate' ? '≈ device region estimate' : '≈ IP country'}',
            platform: d.platform,
            serverLabel: d.node.displayTitle,
          );
        })(),
  ];
}

/// Маленькая кнопка устройств и привязанная к ней выпадающая панель. Один и тот
/// же виджет на Windows и Android, тот же макет повторён на сайте и в
/// расширении.
///
/// ЭТАП 2: слова «Устройства» больше нет и цифра не стоит рядом со значком —
/// это только значок, а счётчик сидит бейджем на самом значке. Так кнопка
/// занимает 40x40 вместо полосы в пол-экрана.
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
                  maxHeight: (screen.height - anchor.dy - 44).clamp(180.0, 400.0),
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
      final int? count = widget.controller.snapshot?.activeTunnels;
      return Semantics(
        button: true,
        label: '${ru ? 'Устройства онлайн' : 'Devices online'}: ${count ?? 0}',
        child: SizedBox(
          // Бейджу нужно немного места за краем плитки, иначе он обрежется.
          width: _chipSize + 6, height: _chipSize + 6,
          child: Stack(clipBehavior: Clip.none, children: <Widget>[
            Material(
              key: _chipKey,
              color: _chipBg,
              borderRadius: BorderRadius.circular(13),
              child: InkWell(
                onTap: _toggle,
                borderRadius: BorderRadius.circular(13),
                child: Container(
                  width: _chipSize, height: _chipSize,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: GlukColors.violet.withOpacity(_open ? .70 : .38)),
                    boxShadow: _open
                        ? <BoxShadow>[BoxShadow(color: GlukColors.violet.withOpacity(.34), blurRadius: 16)]
                        : null,
                  ),
                  child: const Icon(Icons.devices, size: 20, color: GlukColors.violetLight),
                ),
              ),
            ),
            // Счётчик НА значке, а не рядом с ним.
            if (count != null && count > 0) Positioned(
              right: 0, bottom: 0,
              child: Container(
                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: GlukColors.violet2,
                  shape: BoxShape.rectangle,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: GlukColors.bg, width: 2),
                  boxShadow: <BoxShadow>[BoxShadow(color: GlukColors.violet.withOpacity(.55), blurRadius: 8)],
                ),
                child: Text('$count',
                  style: const TextStyle(fontSize: 10.5, height: 1.1, fontWeight: FontWeight.w800, color: _countText)),
              ),
            ),
          ]),
        ),
      );
    },
  );
}

class _AccountDevicesPanel extends StatefulWidget {
  const _AccountDevicesPanel({required this.controller, required this.russian, required this.width, required this.maxHeight, required this.onClose});
  final AccountInsightsController controller;
  final bool russian;
  final double width, maxHeight;
  final VoidCallback onClose;
  @override State<_AccountDevicesPanel> createState() => _AccountDevicesPanelState();
}

class _AccountDevicesPanelState extends State<_AccountDevicesPanel> {
  /// id устройства, чьи подробности открыты стрелкой «>». null — список.
  String? _openedId;

  @override Widget build(BuildContext context) {
    final ru = widget.russian;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: widget.width,
          constraints: BoxConstraints(maxHeight: widget.maxHeight),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: _panelBg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _panelBorder),
            boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x9E000000), blurRadius: 48, offset: Offset(0, 20))],
          ),
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              final snapshot = widget.controller.snapshot;
              // Обычный цикл, а не firstOrNull: этот геттер живёт в
              // package:collection, которого нет в pubspec клиента.
              ActiveTunnelDevice? opened;
              if (_openedId != null) {
                for (final ActiveTunnelDevice d in snapshot?.devices ?? const <ActiveTunnelDevice>[]) {
                  if (d.id == _openedId) {
                    opened = d;
                    break;
                  }
                }
              }
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                Row(children: <Widget>[
                  if (opened != null) _PanelIconButton(
                    icon: Icons.arrow_back_rounded,
                    tooltip: ru ? 'Назад' : 'Back',
                    onTap: () => setState(() => _openedId = null),
                  ),
                  if (opened != null) const SizedBox(width: 6),
                  Expanded(child: Text(
                    opened != null
                        ? opened.deviceName
                        : (ru ? 'Устройства онлайн' : 'Devices online'),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: GlukColors.text0),
                  )),
                  _PanelIconButton(
                    icon: Icons.close_rounded,
                    tooltip: ru ? 'Закрыть' : 'Close',
                    onTap: widget.onClose,
                  ),
                ]),
                const SizedBox(height: 8),
                Flexible(child: opened != null
                    ? SingleChildScrollView(child: _DeviceDetail(device: opened, russian: ru))
                    : ActiveAccountMap(
                        api: widget.controller.api,
                        controller: widget.controller,
                        russian: ru,
                        compact: true,
                        onOpenDevice: (d) => setState(() => _openedId = d.id),
                      )),
              ]);
            },
          ),
        ),
      ),
    );
  }
}

/// Компактная круглая кнопка в шапке панели (назад / закрыть).
class _PanelIconButton extends StatelessWidget {
  const _PanelIconButton({required this.icon, required this.tooltip, required this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  @override Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(width: 30, height: 30, child: Icon(icon, size: 17, color: GlukColors.text1)),
    ),
  );
}

/// Плитка устройства: глиф в сиреневом квадрате, имя, «платформа · время»,
/// маршрут, зелёная точка и КЛИКАБЕЛЬНАЯ стрелка «>» с подробностями.
/// Ровно то же самое в расширении и на сайте.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.russian, this.onOpen});
  final ActiveTunnelDevice device;
  final bool russian;
  final ValueChanged<ActiveTunnelDevice>? onOpen;

  @override Widget build(BuildContext context) {
    final live = device.status == 'ACTIVE';
    return Container(
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: GlukColors.violet.withOpacity(.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GlukColors.violet.withOpacity(.18)),
      ),
      child: Row(children: <Widget>[
        Container(
          width: 36, height: 36,
          decoration: BoxDecoration(color: GlukColors.violet.withOpacity(.2), borderRadius: BorderRadius.circular(12)),
          child: Icon(accountDeviceIcon(device.platform), size: 19, color: GlukColors.violetLight),
        ),
        const SizedBox(width: 10),
        Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(device.deviceName, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: GlukColors.text0)),
          const SizedBox(height: 1),
          Text('${device.platform} · ${formatDuration(Duration(seconds: device.durationSec))}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: GlukColors.text1)),
          const SizedBox(height: 1),
          Text('→ ${device.node.city ?? device.node.displayTitle}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: _routeText)),
          if (device.isCurrent) Padding(padding: const EdgeInsets.only(top: 4), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: GlukColors.violetLight.withOpacity(.15), borderRadius: BorderRadius.circular(999)),
            child: Text(russian ? 'Это устройство' : 'This device',
              style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: GlukColors.violetLight)),
          )),
        ])),
        const SizedBox(width: 6),
        Container(width: 7, height: 7, decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: live ? GlukColors.connected : GlukColors.text2,
          boxShadow: live ? <BoxShadow>[BoxShadow(color: GlukColors.connected.withOpacity(.85), blurRadius: 9)] : null,
        )),
        // ЭТАП 2: стрелка перестала быть картинкой. Это кнопка 34x34 —
        // в неё реально попадает и мышь, и палец.
        Tooltip(
          message: russian ? 'Подробнее об устройстве' : 'Device details',
          child: InkWell(
            onTap: onOpen == null ? null : () => onOpen!(device),
            borderRadius: BorderRadius.circular(10),
            child: const SizedBox(width: 34, height: 34,
              child: Icon(Icons.chevron_right_rounded, size: 19, color: GlukColors.violetLight)),
          ),
        ),
      ]),
    );
  }
}

/// Подробности одного устройства — то, что открывается стрелкой «>».
class _DeviceDetail extends StatelessWidget {
  const _DeviceDetail({required this.device, required this.russian});
  final ActiveTunnelDevice device;
  final bool russian;

  @override Widget build(BuildContext context) {
    final ru = russian;
    final live = device.status == 'ACTIVE';
    final origin = device.origin;
    final where = origin == null
        ? (ru ? 'Не определено' : 'Unknown')
        : [origin.country, origin.countryCode].where((v) => v != null && v.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: GlukColors.violet.withOpacity(.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: GlukColors.violet.withOpacity(.2)),
        ),
        child: Row(children: <Widget>[
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(color: GlukColors.violet.withOpacity(.22), borderRadius: BorderRadius.circular(13)),
            child: Icon(accountDeviceIcon(device.platform), size: 22, color: GlukColors.violetLight),
          ),
          const SizedBox(width: 11),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text(device.platform, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: GlukColors.text0)),
            const SizedBox(height: 3),
            Row(children: <Widget>[
              Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle,
                color: live ? GlukColors.connected : GlukColors.amber)),
              const SizedBox(width: 6),
              Text(live ? (ru ? 'Подключено' : 'Connected') : (ru ? 'Подключение…' : 'Connecting…'),
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: live ? GlukColors.connected : GlukColors.amber)),
            ]),
          ])),
        ]),
      ),
      const SizedBox(height: 9),
      _DetailRow(label: ru ? 'Сервер выхода' : 'Exit server', value: device.node.displayTitle),
      _DetailRow(label: ru ? 'Город узла' : 'Node city', value: device.node.city ?? '—'),
      _DetailRow(label: ru ? 'В сети' : 'Uptime', value: formatDuration(Duration(seconds: device.durationSec))),
      if (device.connectedAt != null)
        _DetailRow(label: ru ? 'Подключено в' : 'Connected at', value: _clock(device.connectedAt!)),
      _DetailRow(label: ru ? 'Местоположение' : 'Location', value: where.isEmpty ? (ru ? 'Не определено' : 'Unknown') : where),
      if (origin != null) _DetailRow(
        label: ru ? 'Точность' : 'Accuracy',
        value: origin.source == 'device-estimate'
            ? (ru ? '≈ оценка региона устройства' : '≈ device region estimate')
            : (ru ? '≈ страна по IP' : '≈ IP country'),
      ),
      if (device.isCurrent) Padding(padding: const EdgeInsets.only(top: 7), child: Text(
        ru ? 'Это устройство, с которого ты сейчас смотришь.' : 'This is the device you are looking at now.',
        style: const TextStyle(fontSize: 11, color: GlukColors.violetLight),
      )),
    ]);
  }

  static String _clock(DateTime value) {
    final local = value.toLocal();
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${two(local.day)}.${two(local.month)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label, value;
  @override Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Expanded(child: Text(label, style: const TextStyle(fontSize: 11, color: GlukColors.text1))),
      const SizedBox(width: 10),
      Flexible(child: Text(value, textAlign: TextAlign.right, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: GlukColors.text0))),
    ]),
  );
}

/// Compatibility name; this widget is deliberately a list only, even for old callers.
class ActiveAccountMap extends StatefulWidget {
  const ActiveAccountMap({super.key, required this.api, this.controller, this.compact = false, this.russian = false, this.showMap = false, this.reduceMotion = false, this.onServiceChanged, this.onOpenDevice});
  final ApiClient api;
  final AccountInsightsController? controller;
  final bool compact, russian, showMap, reduceMotion;
  final ValueChanged<ServiceStatus>? onServiceChanged;
  final ValueChanged<ActiveTunnelDevice>? onOpenDevice;
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
        Padding(padding:const EdgeInsets.only(bottom:9),child:Text(
          ru?'${snapshot.activeTunnels} подключено · лимит устройств ${snapshot.maxDevices}':'${snapshot.activeTunnels} connected · device limit ${snapshot.maxDevices}',
          style:const TextStyle(fontSize:11,color:GlukColors.text1))),
        if(snapshot.service.maintenance) Padding(padding:const EdgeInsets.only(bottom:9),child:Text(
          ru?'Сервис на обслуживании':'Service maintenance',style:const TextStyle(fontSize:11,color:GlukColors.amber))),
        if(snapshot.devices.isEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:20),child:Text(
          ru?'Нет активных подключений':'No active connections',textAlign:TextAlign.center,style:const TextStyle(fontSize:11.5,color:GlukColors.text1))),
        for(final d in snapshot.devices) _DeviceRow(device:d,russian:ru,onOpen:widget.onOpenDevice),
      ],
    );
  }
}
