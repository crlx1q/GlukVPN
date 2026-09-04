import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';
import 'desktop/i18n/desktop_strings.dart';
import 'desktop/logic/startup_plan.dart';
import 'desktop/screens/desktop_login_screen.dart';
import 'desktop/screens/desktop_shell.dart';
import 'desktop/services/app_paths.dart';
import 'desktop/services/desktop_log.dart';
import 'desktop/services/power_monitor.dart';
import 'desktop/services/service_bootstrap.dart';
import 'desktop/services/single_instance.dart';
import 'desktop/services/tunnel_client.dart';
import 'desktop/state/desktop_settings.dart';
import 'desktop/state/desktop_vpn_controller.dart';
import 'desktop/state/tray_controller.dart';
import 'desktop/state/usage_store.dart';
import 'desktop/state/window_controller.dart';
import 'desktop/theme/desktop_theme.dart';
import 'desktop/widgets/desktop_splash.dart';
import 'services/api_client.dart';
import 'services/ping_service.dart';
import 'services/secure_store.dart';
import 'state/auth_controller.dart';

/// Windows entry point.
///
/// Build with:
///   flutter build windows --release --target lib\main_windows.dart
///
/// The Android entry point (lib/main.dart) is untouched.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // --hidden is passed by the autostart registry entry when the user asked to
  // start minimised. It is only ever one of two reasons to start hidden: the
  // saved setting is the other, and it applies to a manual launch as well.
  // The combined decision is startsHidden() below, once settings are loaded.
  final bool hiddenFlag = args.contains(kStartHiddenFlag);

  final AppPaths paths = AppPaths();
  paths.ensureCreated();
  dlog.attach(paths);

  // One client per machine. Two copies meant two tray icons, two heartbeats
  // and two clients fighting over the same pipe and device slot, so the second
  // one now raises the window of the first and says so instead of starting.
  // This runs before any window exists, so nothing flashes on screen.
  if (!SingleInstance.claim()) {
    final SettingsStore existing = SettingsStore(paths: paths);
    await existing.load();
    // ROUND 10 (1.2): ask the running copy to raise its own window before
    // reaching in from outside. Only it knows whether it is currently showing
    // the tray panel or the full window, and someone who launched the
    // shortcut again wants the full window.
    SingleInstance.signalShowRequest();
    SingleInstance.surfaceRunningInstance(
      russian: DesktopStrings.resolve(existing.value.language).isRussian,
    );
    exit(0);
  }

  // The winning copy listens for that request for the rest of its life.
  SingleInstance.armShowRequests();

  await windowManager.ensureInitialized();

  final SettingsStore settings = SettingsStore(paths: paths);
  await settings.load();

  final DesktopSettings saved = settings.value;

  // ROUND 26: one decision, made once, from the flag and the setting. The
  // window options below, WindowController.attach and the shell all read this
  // value; none of them re-derives it.
  final bool startHidden = startsHidden(settings: saved, args: args);
  dlog.write(
    'boot',
    'GlukVPN desktop starting (hidden=$startHidden flag=$hiddenFlag '
        'startMinimized=${saved.startMinimized} '
        'autoConnect=${saved.autoConnect})',
  );

  // ROUND 9 (1.3): restore the developer channel before anything touches the
  // network.
  //
  // AppConfig.activeChannel is what ApiClient resolves its host from and what
  // scopes SecureStore's keys, so restoring it late would bootstrap the
  // session against one control plane and then move the host under it - which
  // shows up as a working login that 401s on the first real request.
  if (saved.channel == 'beta') {
    if (AppConfig.setChannelOverride(AppChannel.beta)) {
      dlog.write('boot', 'developer channel restored: beta');
    } else {
      // Compiled without ALLOW_BETA_CHANNEL. Forget the stored choice instead
      // of keeping a preference that can never apply.
      dlog.warn('boot', 'stored beta channel refused by this build');
      await settings.save(saved.copyWith(channel: 'prod'));
    }
  }

  // The window is a fixed panel now, so a stored width and height would only
  // resurrect the old oversized geometry. Position is still restored.
  const Size windowSize = AppConfig.desktopDefaultSize;

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: windowSize,
      minimumSize: AppConfig.desktopMinSize,
      center: saved.windowX == null,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    ),
    () async {
      final bool hasValidPosition = saved.windowX != null &&
          saved.windowY != null &&
          saved.windowX! > -10000 &&
          saved.windowY! > -10000;
      if (hasValidPosition) {
        await windowManager.setPosition(
          Offset(saved.windowX!, saved.windowY!),
        );
      } else {
        await windowManager.center();
      }
      // The window cannot be resized or maximised: the composition is designed
      // for exactly one size, and stretching it is what left empty bands above
      // and below the map.
      await windowManager.setResizable(false);

      // "Start minimised" is a primary feature, not an autostart detail. The
      // autostart entry passes --hidden, but launching by hand has to obey the
      // switch as well - that is why the setting looked broken.
      //
      // Nothing here ever calls show() on a hidden start, and the vendored
      // runner (windows_overrides/runner/flutter_window.cpp) no longer shows
      // the window on the first frame either, so a tray-only start paints
      // nothing at all.
      if (startHidden) {
        dlog.write('boot', 'starting hidden, tray only');
      } else {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );

  runApp(
    GlukDesktopApp(
      paths: paths,
      settings: settings,
      startHidden: startHidden,
    ),
  );
}

class GlukDesktopApp extends StatefulWidget {
  const GlukDesktopApp({
    super.key,
    required this.paths,
    required this.settings,
    required this.startHidden,
  });

  final AppPaths paths;
  final SettingsStore settings;
  final bool startHidden;

  @override
  State<GlukDesktopApp> createState() => _GlukDesktopAppState();
}

class _GlukDesktopAppState extends State<GlukDesktopApp> {
  late final SecureStore _store;
  late final ApiClient _api;
  late final AuthController _auth;
  late final WindowsTunnelClient _tunnel;
  late final UsageStore _usage;
  late final DesktopVpnController _vpn;
  late final WindowController _window;
  late final TrayController _tray;

  /// Watches the battery so animations can stand down on their own.
  final PowerMonitor _power = PowerMonitor();

  /// Polls the single-instance "show yourself" event. A zero-timeout wait on
  /// an already-open handle, so this costs nothing between requests.
  Timer? _showRequests;

  DesktopStrings _strings = DesktopStrings.english;
  bool _ready = false;
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    _strings = DesktopStrings.resolve(widget.settings.value.language);
    _boot();

    // Requirement 3: the splash is a fixed short beat, not a loading gate.
    Timer(AppConfig.splashDuration, () {
      if (mounted) setState(() => _splashDone = true);
    });
  }

  Future<void> _boot() async {
    _store = SecureStore();
    _api = ApiClient();
    _auth = AuthController(api: _api, store: _store);

    _tunnel = WindowsTunnelClient(pipeName: AppConfig.tunnelPipeName);
    _usage = UsageStore(paths: widget.paths);

    _vpn = DesktopVpnController(
      api: _api,
      auth: _auth,
      tunnel: _tunnel,
      settings: widget.settings,
      usage: _usage,
      ping: PingService(),
      // The controller probes the service without elevating, and only asks for
      // elevation when the user presses Connect or "Install service".
      service: ServiceBootstrap(paths: widget.paths),
    );

    _window = WindowController(settings: widget.settings);
    _tray = TrayController(vpn: _vpn, window: _window, strings: _strings);

    // Banners and failure reasons produced inside the controller are read by
    // the user, so it has to know which language the UI is in.
    _vpn.russian = _strings.isRussian;

    // Battery and power-saver state feed the single Animations switch. This is
    // purely cosmetic: the tunnel never reacts to it.
    unawaited(_power.start());

    _window.onExitRequested = _exit;

    // Attach the auth listener BEFORE restoring the session.
    //
    // This is the bug that made the desktop client show an empty server list:
    // the listener used to be added after `_auth.bootstrap()`, so when a saved
    // session was restored the authenticated transition happened with nobody
    // listening, and the VPN controller never learned it could call
    // GET /api/nodes.
    _auth.addListener(_onAuthChanged);

    // Order matters for a tray-only start (ROUND 26):
    //
    //  1. the window is attached hidden - nothing is shown;
    //  2. the tray icon exists, so a connect that follows has somewhere to
    //     report to (TrayController listens to the controller, not to the
    //     window, so it tracks the phase whether or not a window ever opens);
    //  3. the session is restored; the auth listener above runs the
    //     controller's bootstrap, which probes the service, adopts a tunnel the
    //     service may already hold, and only then decides on auto-connect via
    //     startupPlan(). A bootstrap that arrives while one is running is
    //     replayed, never dropped, so a slow service probe cannot swallow it.
    await _window.attach(startHidden: widget.startHidden);
    await _tray.attach();

    _showRequests = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) {
        if (!SingleInstance.consumeShowRequest()) return;
        unawaited(_window.surfaceForSecondInstance());
      },
    );

    try {
      await _auth.bootstrap();
    } catch (e) {
      dlog.error('boot', 'auth bootstrap failed', e);
    }

    try {
      await _usage.load(owner: _auth.user?.publicId);
    } catch (e) {
      dlog.error('boot', 'usage load failed', e);
    }

    // Independent of the tunnel service and of the auth result: bootstrap is
    // fault-isolated and retries the node list on its own.
    unawaited(_vpn.bootstrap());

    if (mounted) setState(() => _ready = true);
    dlog.write('boot', 'ready (auth=${_auth.stage})');
  }

  void _onAuthChanged() {
    if (_auth.stage == AuthStage.authenticated) {
      unawaited(_usage.load(owner: _auth.user?.publicId));
      unawaited(_vpn.bootstrap());
      // bootstrap() is re-entrancy guarded; this makes sure a session restored
      // while an earlier bootstrap was still running still gets its nodes.
      unawaited(_vpn.retryNodes());
    }
    if (mounted) setState(() {});
  }

  void _onLanguageChanged(String preference) {
    setState(() => _strings = DesktopStrings.resolve(preference));
    _tray.updateStrings(_strings);
    _vpn.russian = _strings.isRussian;
  }

  /// Tray -> Exit. Requirement 11: this is the only path that really quits.
  Future<void> _exit() async {
    await _vpn.shutdown(
      disconnectTunnel: widget.settings.value.disconnectOnExit,
    );
    await _tray.dispose();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  @override
  void dispose() {
    _showRequests?.cancel();
    _auth.removeListener(_onAuthChanged);
    _power.dispose();
    _window.dispose();
    _vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GlukVPN',
      debugShowCheckedModeBanner: false,
      theme: DesktopTheme.build(),
      // Guarantees a Material ancestor and a real ambient text style for the
      // whole tree. Without it Flutter falls back to its error text style,
      // which is what drew a yellow double underline under every label in the
      // first build.
      builder: DesktopTheme.appBuilder,
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    final bool showSplash = !_splashDone ||
        !_ready ||
        _auth.stage == AuthStage.unknown ||
        _auth.stage == AuthStage.restoring;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: showSplash
          ? const DesktopSplash(key: ValueKey<String>('splash'))
          : _auth.stage == AuthStage.authenticated
              ? DesktopShell(
                  key: const ValueKey<String>('shell'),
                  vpn: _vpn,
                  auth: _auth,
                  settings: widget.settings,
                  window: _window,
                  tray: _tray,
                  power: _power,
                  strings: _strings,
                  onLanguageChanged: _onLanguageChanged,
                )
              : DesktopLoginScreen(
                  key: const ValueKey<String>('login'),
                  auth: _auth,
                  strings: _strings,
                ),
    );
  }
}
