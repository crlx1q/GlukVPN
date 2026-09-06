import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../i18n/app_strings.dart';
import '../models/device_limit.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/account_insights_controller.dart';
import '../state/channel_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../utils/geo.dart';
import '../utils/geo_dictionary.dart';
import '../utils/map_view.dart';
import '../widgets/connect_button.dart';
import '../widgets/active_account_map.dart';
import '../widgets/device_limit_dialog.dart';
import '../widgets/dotted_world.dart';
import '../widgets/glass.dart';
import '../widgets/logo.dart';
import '../widgets/skeleton.dart';

/// The main screen: dotted world map behind a 150 px power button, a state
/// badge, the selected node, a 2x2 readout grid and the traffic panel.
///
/// Everything on it is real: the public IP comes from a probe made *through*
/// the tunnel, the VPN IP is the address the control plane leased, the duration
/// counts from the session's `connectedAt`, and the ping is an ICMP round-trip
/// to the node's gateway inside the tunnel (falling back to an HTTPS round-trip
/// to the control API, which is labelled differently so the number is never
/// passed off as tunnel latency).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onOpenServers,
    this.onOpenProfile,
  });

  final VoidCallback onOpenServers;
  final VoidCallback? onOpenProfile;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final AccountInsightsController _accountMap;
  @override void initState() {
    super.initState();
    _accountMap = AccountInsightsController(context.read<VpnController>().api);
    _accountMap.addListener(_mapChanged);
    _accountMap.setVisible(true);
    WidgetsBinding.instance.addObserver(this);
  }
  void _mapChanged() { if (!mounted)return; if(_accountMap.snapshot!=null)context.read<VpnController>().handleServiceStatus(_accountMap.snapshot!.service);setState(() {}); }
  @override void didChangeAppLifecycleState(AppLifecycleState state) => _accountMap.setVisible(state == AppLifecycleState.resumed);
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountMap.removeListener(_mapChanged); _accountMap.dispose(); super.dispose();
  }

  /// Where to draw "you".
  ///
  /// The control plane's own view of where the request came from goes first: it
  /// is the only source that can tell a Russian-language phone in Moscow from
  /// the same phone in Kazakhstan. The device's clock and locale are only the
  /// fallback. No GPS, no permission prompt, and never finer than a country.
  SelfLocation _selfFor(AuthUser? user) => approximateSelfLocation(
        originCountryCode: user?.originCountryCode,
        originCountryName: user?.originCountry,
        originRegion: user?.originRegion,
      );

  Future<void> _toggle(VpnController vpn) async {
    if (vpn.busy) return;
    // Короткая отдача на само нажатие: палец получает ответ раньше,
    // чем сеть. Вторая, более заметная — в контроллере, когда ключ
    // реально заработал.
    HapticFeedback.lightImpact().ignore();
    if (vpn.isConnected || vpn.state == VpnUiState.connecting) {
      await vpn.disconnect();
      return;
    }
    if (vpn.isTransitioning) return;

    final AuthController auth = context.read<AuthController>();
    // Clear any stale verdict first, so what we read back belongs to this tap.
    auth.clearDeviceLimit();
    await vpn.connect();
    if (!mounted) return;

    // Connecting registers this device first, and registration is refused when
    // every slot on the plan is taken. The controller records the occupied
    // slots rather than only failing, which turns a dead end into one tap.
    // Read from that state rather than catching: connect() handles its own
    // errors and does not rethrow.
    final DeviceLimitDetails? limit = auth.deviceLimit;
    if (limit == null || !limit.isActionable) return;

    final String? freed = await showDeviceLimitDialog(
      context: context,
      details: limit,
      strings: context.strings,
    );
    if (freed == null || !mounted) return;

    try {
      await auth.freeDeviceSlot(freed);
      if (mounted) await vpn.connect();
    } on ApiException {
      // freeDeviceSlot leaves the limit state in place, so the next tap offers
      // the list again instead of failing silently.
    }
  }

  ConnectPhase _phaseFor(VpnUiState state) {
    switch (state) {
      case VpnUiState.connected:
        return ConnectPhase.connected;
      case VpnUiState.connecting:
        return ConnectPhase.connecting;
      case VpnUiState.disconnecting:
        return ConnectPhase.disconnecting;
      case VpnUiState.disconnected:
        return ConnectPhase.idle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final VpnController vpn = context.watch<VpnController>();
    final AuthController auth = context.watch<AuthController>();
    final MotionController motion = context.watch<MotionController>();
    final TextTheme text = Theme.of(context).textTheme;

    final VpnNodeInfo? node = vpn.selectedNode;
    final SelfLocation self = _selfFor(auth.user);
    final MapPoint? serverPoint = countryPoint(node?.countryCode);
    // Every node that is up right now, so the map shows the real fleet.
    final List<MapPoint> fleet = vpn.nodes
        .where((VpnNodeInfo item) => item.online)
        .map((VpnNodeInfo item) => countryPoint(item.countryCode))
        .whereType<MapPoint>()
        .toList();

    final (String badgeLabel, Color badgeTone) = switch (vpn.state) {
      VpnUiState.connected => (s.stateConnected, GlukColors.connected),
      VpnUiState.connecting => (s.stateConnecting, GlukColors.amber),
      VpnUiState.disconnecting => (s.stateDisconnecting, GlukColors.amber),
      VpnUiState.disconnected => (s.stateInactive, GlukColors.text2),
    };

    // The four readouts share one rule: a figure that is on its way is a
    // skeleton, a figure that does not apply is a dash, and nothing from the
    // previous session is ever shown in the gap. "On its way" is the whole of
    // connecting and disconnecting, plus the moments after the tunnel is up
    // while the exit address and the first ping are still out.
    final bool connected = vpn.isConnected;
    final bool transitioning = vpn.isTransitioning;
    final bool animate = !motion.reduceMotion;
    final String? pingText =
        connected ? vpn.ping.milliseconds?.toString() : null;

    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: _MapBackdrop(
            motion: motion,
            overview: false,
            selfPoint: self.point,
            serverPoint: serverPoint,
            fleet: fleet,
            accountArcs: accountMapArcs(_accountMap.snapshot),
            connected: vpn.isConnected || (_accountMap.snapshot?.activeTunnels ?? 0) > 0,
            live: vpn.isConnected || vpn.state == VpnUiState.connecting,
            connecting: vpn.state == VpnUiState.connecting,
            disconnecting: vpn.state == VpnUiState.disconnecting,
          ),
        ),
        const Positioned.fill(child: IgnorePointer(child: _MapFade())),
        SafeArea(
          bottom: false,
          child: Column(
            children: <Widget>[
              _Header(
                username: auth.user?.username,
                publicIdLabel: auth.user?.publicIdLabel,
                onOpenProfile: widget.onOpenProfile,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 108),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Center(
                        child: StatusBadge(
                          label: badgeLabel,
                          tone: badgeTone,
                          blinking: vpn.isTransitioning,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Center(child: _LocationChip(self: self)),
                      const SizedBox(height: 7),
                      Center(
                        child: GlukConnectButton(
                          phase: _phaseFor(vpn.state),
                          reduceMotion: motion.reduceMotion,
                          onTap: vpn.busy ? null : () => _toggle(vpn),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _ServerRow(
                        node: node,
                        loading: vpn.loadingNodes,
                        animate: animate,
                        onTap: widget.onOpenServers,
                      ),
                      const SizedBox(height: 10),
                      // All account routes live on the backdrop; no second map card.
                      const SizedBox(height: 14),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: s.publicIp,
                              child: ValueOrSkeleton(
                                // Exit address through the tunnel, or the
                                // phone's own address while disconnected -
                                // never one standing in for the other.
                                value: vpn.publicIp,
                                loading: transitioning ||
                                    (connected && vpn.exitIp == null),
                                characters: 15,
                                animate: animate,
                                style: StatCell.valueStyle(
                                  context,
                                  color: connected ? GlukColors.connected : null,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: s.vpnIp,
                              child: ValueOrSkeleton(
                                // The lease is only shown once the tunnel is
                                // up; while connecting it is a promise, not an
                                // address the phone is using.
                                value: connected ? vpn.assignedIp : null,
                                loading: transitioning ||
                                    (connected && vpn.assignedIp == null),
                                characters: 15,
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: StatCell(
                              label: s.duration,
                              child: ValueOrSkeleton(
                                value: connected
                                    ? formatDuration(vpn.connectedFor)
                                    : null,
                                loading: transitioning,
                                characters: 8,
                                emptyLabel: '00:00:00',
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: StatCell(
                              label: s.ping,
                              child: ValueOrSkeleton(
                                value: pingText,
                                loading: transitioning ||
                                    (connected && pingText == null),
                                characters: 5,
                                animate: animate,
                                style: StatCell.valueStyle(context),
                              ),
                              trailing: Text(
                                connected && vpn.ping.ok
                                    ? '${s.ms} \u00b7 ${vpn.ping.sourceLabel}'
                                    : s.ms,
                                style: text.bodySmall,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      _TrafficPanel(rx: vpn.bytesRx, tx: vpn.bytesTx),
                      if (node != null && !node.online) ...<Widget>[
                        const SizedBox(height: 12),
                        InlineNotice(
                          message: s.nodeOffline(node.displayTitle),
                          tone: GlukColors.amber,
                        ),
                      ],
                      if (!auth.subscriptionActive) ...<Widget>[
                        const SizedBox(height: 12),
                        InlineNotice(
                          message: s.planInactiveNotice,
                          tone: GlukColors.amber,
                        ),
                      ],
                      if (vpn.notice != null) ...<Widget>[
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: vpn.clearMessages,
                          child: InlineNotice(
                            message: vpn.notice!,
                            tone: GlukColors.violetLight,
                          ),
                        ),
                      ],
                      if (vpn.error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        InkWell(
                          onTap: vpn.clearMessages,
                          child: InlineNotice(message: vpn.error!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // На телефоне карта остаётся только фоном за героем: отдельной карточки
        // с картой посередине и режима «рассмотреть карту» больше нет —
        // всё живёт в той же панели «Устройства», что и на Windows.
        Positioned(top:MediaQuery.paddingOf(context).top+64,right:12,child:AccountDevicesButton(controller:_accountMap,russian:s.isRussian)),
      ],
    );
  }
}

/// The map, the "you" marker, the node marker and the animated cable between
/// them.
///
/// ROUND 29: the map spawns instead of being thrown at the screen.
///
/// Two different things made the first second of a cold start look broken, and
/// both are fixed here rather than papered over by slowing the sway down:
///
///  * **Framing.** [FlatMapView.topAnchored] is computed from `centre`, and
///    `centre` moves twice while the app settles: once when the node list
///    arrives (there is suddenly an exit to frame) and once when the profile's
///    origin country arrives (the "you" marker stops being a locale guess).
///    Each recompute used to land on the very next frame - that is the jump.
///    Zoom and focus are tweened now, so the camera glides to the new framing
///    instead of teleporting to it.
///  * **Spawn.** The map fades in over 280 ms and the idle sway is held dead
///    centre until that fade is over, so the first thing on screen is the
///    centred world rather than a world already sliding sideways.
class _MapBackdrop extends StatefulWidget {
  const _MapBackdrop({
    required this.motion,
    required this.selfPoint,
    required this.serverPoint,
    required this.fleet,
    required this.accountArcs,
    this.overview = false,
    required this.connected,
    required this.live,
    this.connecting = false,
    this.disconnecting = false,
  });

  final MotionController motion;
  final MapPoint selfPoint;
  final MapPoint? serverPoint;
  final List<MapPoint> fleet;
  final List<ConnectionArc> accountArcs;
  final bool overview;
  final bool connected;
  final bool live;
  final bool connecting;
  final bool disconnecting;

  @override
  State<_MapBackdrop> createState() => _MapBackdropState();
}

class _MapBackdropState extends State<_MapBackdrop>
    with SingleTickerProviderStateMixin {
  /// The spawn fade, inside the 250-300 ms the design asks for: long enough to
  /// read as an appearance, short enough that nobody waits for the screen.
  static const Duration spawnDuration = Duration(milliseconds: 280);

  /// A camera move. Long enough to read as a glide, short enough that the
  /// picture has settled before a thumb reaches CONNECT.
  static const Duration reframeDuration = Duration(milliseconds: 620);

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.motion.transition(spawnDuration),
  );

  late final Animation<double> _spawn = CurvedAnimation(
    parent: _fade,
    curve: Curves.easeOut,
  );

  /// True once the map is all the way in. Only then does anything move.
  bool _spawnDone = false;

  /// ЭТАП 2: карта не показывается, пока рамка не окончательная.
  ///
  /// Прежнее поведение выглядело как «карта быстро летит справа в центр», и
  /// причина была не в самой анимации, а в том, что первый кадр строился по
  /// черновой рамке: сервер ещё не выбран, точка «я» — догадка по локали,
  /// а через долю секунды приходили настоящие данные и камера ехала к ним
  /// уже на виду. Теперь первая постановка камеры происходит мгновенно и
  /// невидимо, и только потом карта проявляется — сразу с кадром «я → сервер»
  /// посередине.
  bool _framed = false;
  Timer? _settle;

  /// Сколько ждём настоящую рамку. Дольше ждать нельзя: если сети нет,
  /// карта всё равно обязана появиться.
  static const Duration framingGrace = Duration(milliseconds: 650);

  /// Есть что кадрировать: или живые нитки аккаунта, или выбранный сервер.
  bool get _hasRoute => widget.accountArcs.isNotEmpty || widget.serverPoint != null;

  @override
  void initState() {
    super.initState();
    _fade.addStatusListener(_onFadeStatus);
    if (_hasRoute) {
      _markFramed();
    } else {
      _settle = Timer(framingGrace, _markFramed);
    }
  }

  void _markFramed() {
    _settle?.cancel();
    _settle = null;
    if (_framed) return;
    _framed = true;
    if (mounted) setState(() {});
    _fade.forward();
  }

  @override
  void didUpdateWidget(covariant _MapBackdrop old) {
    super.didUpdateWidget(old);
    if (!_framed && _hasRoute) _markFramed();
  }

  void _onFadeStatus(AnimationStatus status) {
    if (_spawnDone || status != AnimationStatus.completed) return;
    setState(() => _spawnDone = true);
  }

  @override
  void dispose() {
    _settle?.cancel();
    _fade.removeStatusListener(_onFadeStatus);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final MapPoint selfPoint = widget.selfPoint;
    final MapPoint? serverPoint = widget.serverPoint;

    // The map is pinned to the top of the screen and covers most of its
    // height, so it reads as a world instead of a band sitting behind the
    // readouts. Those numbers depend on the viewport, so they are computed
    // rather than guessed - a hard-coded zoom is a strip on some phones and a
    // close-up on others. Framing runs between "you" and the chosen exit, so
    // the route you are about to take is what the picture is about.
    // ЭТАП 3: карта больше не подгоняет зум под точки.
    //
    // `fitConnections` пересчитывал И зум, И центр по рамке всех точек, а
    // список устройств приходит опросом раз в 5 секунд. Любое изменение
    // — новое устройство, ушедшее устройство, уточнённая геолокация — давало
    // новую рамку, и камера ехала к ней. Именно это выглядело как «фигуры
    // резко телепаются вправо-влево». Оттуда же и скачущий размер
    // маркеров: их масштаб был привязан к зуму.
    //
    // Возвращаем поведение старого клиента: зум постоянный, карта прижата
    // к верху и там и остаётся, а кадр строится ТОЛЬКО по горизонтали —
    // ровно как просили: «по горизонтальной линии, а не буквально
    // посередине телефона». `topAnchored` берёт только `centreOn.fx`,
    // вертикаль он считает сам от высоты экрана.
    double minX = selfPoint.x;
    double maxX = selfPoint.x;
    void span(double x) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
    }
    if (serverPoint != null) span(serverPoint.x);
    // И второе: кадр строится ТОЛЬКО по себе и выбранному серверу —
    // ровно как в старом клиенте. Раньше в рамку входили ещё и
    // концы чужих ниток, а список устройств приходит опросом раз в
    // 5 секунд: любое появление или исчезновение устройства давало
    // новый центр, и весь мир медленно ехал вбок. Именно это и
    // выглядело как «шахматные фигуры».
    final FlatMapView view = FlatMapView.topAnchored(
      viewport: MediaQuery.sizeOf(context),
      centreOn: MapPoint((minX + maxX) / 2, selfPoint.y),
      coverage: 0.88,
      topPadding: -6,
    );
    // Пока карта невидима, камера ставится мгновенно: никто не должен
    // видеть, как мир подъезжает к своему кадру. После появления любое
    // изменение рамки — смена сервера, новое устройство — снова плавное.
    final Duration glide = _framed ? widget.motion.transition(reframeDuration) : Duration.zero;

    return FadeTransition(
      opacity: _spawn,
      // Neither tween carries a `begin`, on purpose: the first build lands on
      // the real framing instead of gliding towards it from an invented one,
      // and every later change animates from wherever the camera is now.
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: view.zoom),
        duration: glide,
        curve: Curves.easeOutCubic,
        builder: (BuildContext context, double zoom, Widget? _) =>
            TweenAnimationBuilder<Offset>(
          tween: Tween<Offset>(end: view.focus),
          duration: glide,
          curve: Curves.easeOutCubic,
          builder: (BuildContext context, Offset focus, Widget? _) =>
              _world(context, zoom, focus),
        ),
      ),
    );
  }

  /// The world at the framing the camera has reached: the dots, the two
  /// markers, the arc between them and the idle loops.
  Widget _world(BuildContext context, double zoom, Offset focus) {
    final MotionController motion = widget.motion;
    final MapPoint selfPoint = widget.selfPoint;
    final MapPoint? serverPoint = widget.serverPoint;
    final List<MapPoint> fleet = widget.fleet;
    final bool connected = widget.connected;
    final bool live = widget.live;

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: live ? 1 : 0),
      duration: motion.transition(const Duration(milliseconds: 900)),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double arc, Widget? _) {
        return LoopingBuilder(
          duration: GlukMotion.connectionDash,
          reduceMotion: motion.reduceMotion,
          builder: (BuildContext context, double dash) {
            return LoopingBuilder(
              duration: GlukMotion.mapPulse,
              reduceMotion: motion.reduceMotion,
              frozenValue: 0.35,
              builder: (BuildContext context, double pulse) {
                return LoopingBuilder(
                  duration: const Duration(seconds: 14),
                  reduceMotion: motion.reduceMotion,
                  frozenValue: 0.2,
                  builder: (BuildContext context, double orbit) {
                    // One turn of longitude every four minutes. Imperceptible
                    // frame to frame, but it is the difference between a world
                    // and wallpaper - and a full 360 loop wraps seamlessly.
                    return LoopingBuilder(
                      duration: const Duration(seconds: 240),
                      // ROUND 29: the sway waits for the spawn fade. While the
                      // map is appearing the loop is held at its centre, so
                      // the picture cannot slide sideways before it is even
                      // fully visible.
                      reduceMotion: motion.reduceMotion || !_spawnDone,
                      frozenValue: 0,
                      builder: (BuildContext context, double drift) {
                        // ПУНКТ 4: фазы подключения теперь видны на карте так
                        // же, как на ПК. Пока идёт попытка — нитка
                        // вырисовывается снова и снова (это «идёт работа», а не
                        // застывшая линия), при отключении она втягивается
                        // обратно, а в спокойных состояниях работает обычный
                        // плавный tween.
                        // Фаза 3 раньше брала прогресс из того же
                        // бесконечного цикла dash, а он крутится всегда:
                        // нить начинала втягиваться с случайного места и могла
                        // дёрнуться вверх вместо плавного ухода. Отключение
                        // теперь ведёт tween `arc` (live уже стал false), который
                        // привязан именно к моменту нажатия — как на ПК.
                        final double drawn = widget.connecting
                            ? dash.clamp(0.0, 1.0)
                            : arc;
                        return DottedWorld(
                          zoom: widget.overview ? 1 : zoom,
                          focus: widget.overview ? const Offset(.5,.5) : focus,
                          dotOpacity: 0.58,
                          // ROUND 6: the map used to scroll one way for ever,
                          // like a marquee. Folding the 0 -> 1 drift into a
                          // triangle wave makes it travel out and then back,
                          // which is what the desktop client already does and
                          // what reads as a living map instead of a ticker.
                          // ROUND 28: the sway has to *start* in the middle
                          // too. A 0 -> 1 -> 0 triangle begins at its own
                          // minimum, so the first frame was twelve degrees to
                          // the left - the map spawned off-centre with you and
                          // the line pushed against the right edge, and only
                          // drifted into place a minute later. Centred wave:
                          // frame one is exactly the midpoint between you and
                          // the exit.
                          driftDegrees: centredSway(drift) * 12,
                          selfPoint: selfPoint,
                          // Глиф внутри фиолетового маркера «я», когда туннеля ещё нет.
                          selfPlatform: 'phone',
                          serverPoint: serverPoint,
                          nodePoints: fleet,
                          accountArcs: widget.accountArcs,
                          arcProgress: drawn,
                          arcPhase: dash,
                          orbitalPhase: orbit,
                          pulse: live ? pulse : 0,
                          connected: connected,
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// A sway that both starts and ends in the middle.
///
/// Returns -1..1 for a 0..1 input, running 0 -> +1 -> 0 -> -1 -> 0. A plain
/// triangle wave starts at one extreme, which is what pushed the world to one
/// side on the very first frame; this one opens dead centre and is symmetric
/// around it. Both ends are 0, so the loop is still seamless.
double centredSway(double t) {
  final double phase = t - t.floorToDouble();
  if (phase < 0.25) return phase * 4;
  if (phase < 0.75) return 2 - phase * 4;
  return phase * 4 - 4;
}

/// `.map-stage` mask - the map fades out towards the bottom so the readouts sit
/// on a calm background.
class _MapFade extends StatelessWidget {
  const _MapFade();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color(0x000A0714),
            Color(0x1A0A0714),
            Color(0x8A0A0714),
            Color(0xD90A0714),
          ],
          stops: <double>[0, 0.38, 0.72, 1],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}

/// "Roughly here": where the connection appears to come from, as the control
/// plane saw it. Country-level, never a street, and never a permission prompt.
class _LocationChip extends StatelessWidget {
  const _LocationChip({required this.self});

  final SelfLocation self;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final String flag = countryFlag(self.countryCode ?? '');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(
          Icons.my_location_rounded,
          size: 12,
          color: GlukColors.text2,
        ),
        const SizedBox(width: 6),
        Text(
          s.you,
          style: text.bodySmall?.copyWith(color: GlukColors.text2),
        ),
        const SizedBox(width: 6),
        if (flag.isNotEmpty) ...<Widget>[
          Text(flag, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 5),
        ],
        Text(
          // Through the shared dictionary, so the country reads in the
          // interface language rather than always in English.
          self.localizedPlace(russian: s.isRussian),
          style: text.bodySmall?.copyWith(color: GlukColors.text1),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.username,
    required this.publicIdLabel,
    required this.onOpenProfile,
  });

  final String? username;
  final String? publicIdLabel;
  final VoidCallback? onOpenProfile;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ChannelController channel = context.watch<ChannelController>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 6),
      child: Row(
        children: <Widget>[
          const GlukLogo(size: 34, glow: false),
          const SizedBox(width: 10),
          Text('GlukVPN', style: text.titleMedium),
          // Internal builds only. A release APK talks to a single control plane
          // and never labels itself.
          if (AppConfig.betaChannelAvailable && channel.isBeta) ...<Widget>[
            const SizedBox(width: 8),
            _BetaTag(label: channel.versionOf(channel.active)?.label ?? 'BETA'),
          ],
          const Spacer(),
          _ProfileChip(
            username: username,
            publicIdLabel: publicIdLabel,
            onTap: onOpenProfile,
          ),
        ],
      ),
    );
  }
}

/// Amber, never violet: on BETA you are talking to a different database, and
/// the badge has to be impossible to confuse with production.
class _BetaTag extends StatelessWidget {
  const _BetaTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: GlukColors.amber.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: GlukColors.amber.withOpacity(0.45)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: GlukColors.amber, fontSize: 10),
      ),
    );
  }
}

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
    required this.username,
    required this.publicIdLabel,
    required this.onTap,
  });

  final String? username;
  final String? publicIdLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String name = username ?? context.strings.account.toLowerCase();
    final String initial =
        name.isEmpty ? '?' : name.characters.first.toUpperCase();

    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: GlukGradients.arrow,
            ),
            child: Text(
              initial,
              style: text.labelSmall?.copyWith(color: GlukColors.bg),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(name, style: text.bodySmall?.copyWith(color: GlukColors.text0)),
              if (publicIdLabel != null && publicIdLabel!.isNotEmpty)
                Text(
                  publicIdLabel!,
                  style: text.bodySmall?.copyWith(fontSize: 9.5),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The selected node, tappable straight through to the server list.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.node,
    required this.loading,
    required this.animate,
    required this.onTap,
  });

  final VpnNodeInfo? node;
  final bool loading;

  /// False under reduce-motion: the loading skeleton then holds still.
  final bool animate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    if (node == null) {
      return GlassPanel(
        radius: 999,
        padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
        onTap: onTap,
        child: Row(
          children: <Widget>[
            const FlagCircle(flag: '\u{1F310}'),
            const SizedBox(width: 10),
            // A bar the size of a place name while the list loads: the row
            // keeps its shape and nothing has to be read and then unread.
            if (loading)
              SkeletonText(
                characters: 14,
                style: text.titleMedium,
                animate: animate,
              )
            else
              Text(context.strings.noServerAvailable, style: text.titleMedium),
            const Spacer(),
            const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
          ],
        ),
      );
    }

    // Country and city through the shared dictionary, like the server list,
    // so the chip reads "Германия · Франкфурт" on a Russian phone.
    final bool russian = context.strings.isRussian;
    final String title = localizeCountry(
      node!.countryCode,
      russian: russian,
      fallback: node!.displayTitle,
    );
    final String city = localizeCity(node!.city, russian: russian);
    final String subtitle = city.isNotEmpty ? city : node!.displaySubtitle;

    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(10, 9, 14, 9),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          FlagCircle(flag: countryFlag(node!.countryCode)),
          const SizedBox(width: 10),
          Text(title, style: text.titleMedium),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '\u00b7 $subtitle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
          ),
          const Spacer(),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: node!.online ? GlukColors.connected : GlukColors.text2,
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
        ],
      ),
    );
  }
}

/// `.traffic` - WireGuard's own byte counters, reported by the node agent.
class _TrafficPanel extends StatelessWidget {
  const _TrafficPanel({required this.rx, required this.tx});

  final int rx;
  final int tx;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;

    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.swap_vert_rounded, size: 15, color: GlukColors.text2),
              const SizedBox(width: 6),
              Text(s.traffic.toUpperCase(), style: text.labelMedium),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _TrafficItem(
                  icon: Icons.south_rounded,
                  label: s.downloaded,
                  value: formatBytes(rx),
                  tone: GlukColors.violetLight,
                ),
              ),
              Expanded(
                child: _TrafficItem(
                  icon: Icons.north_rounded,
                  label: s.uploaded,
                  value: formatBytes(tx),
                  tone: GlukColors.blue,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TrafficItem extends StatelessWidget {
  const _TrafficItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(icon, size: 13, color: tone),
            const SizedBox(width: 5),
            Text(label, style: text.bodySmall),
          ],
        ),
        const SizedBox(height: 4),
        Text(value, style: text.labelLarge),
      ],
    );
  }
}
