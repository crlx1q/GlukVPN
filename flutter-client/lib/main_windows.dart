import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';
import 'desktop/i18n/desktop_strings.dart';
import 'desktop/screens/desktop_login_screen.dart';
import 'desktop/screens/desktop_shell.dart';
import 'desktop/services/app_paths.dart';
import 'desktop/services/desktop_log.dart';
import 'desktop/services/service_bootstrap.dart';
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
  // start minimised.
  final bool startHidden = args.contains('--hidden');

  await windowManager.ensureInitialized();

  final AppPaths paths = AppPaths();
  paths.ensureCreated();
  dlog.attach(paths);
  dlog.write('boot', 'GlukVPN desktop starting (hidden=$startHidden)');

  final SettingsStore settings = SettingsStore(paths: paths);
  await settings.load();

  final DesktopSettings saved = settings.value;
  final Size windowSize = Size(
    saved.windowWidth ?? AppConfig.desktopDefaultSize.width,
    saved.windowHeight ?? AppConfig.desktopDefaultSize.height,
  );

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: windowSize,
      minimumSize: AppConfig.desktopMinSize,
      center: saved.windowX == null,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      title: 'GlukVPN',
    ),
    () async {
      if (saved.windowX != null && saved.windowY != null) {
        await windowManager.setPosition(
          Offset(saved.windowX!, saved.windowY!),
        );
      }
      // Requirement 11: honour "start minimised" by never showing the window.
      if (!(startHidden && saved.startMinimized)) {
        await windowManager.show();
        await windowManager.focus();
      }
    },
  );

  runApp(
    GlukDesktopApp(
      paths: paths,
      settings: settings,
      startHidden: startHidden && saved.startMinimized,
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

    _window.onExitRequested = _exit;

    // Attach the auth listener BEFORE restoring the session.
    //
    // This is the bug that made the desktop client show an empty server list:
    // the listener used to be added after `_auth.bootstrap()`, so when a saved
    // session was restored the authenticated transition happened with nobody
    // listening, and the VPN controller never learned it could call
    // GET /api/nodes.
    _auth.addListener(_onAuthChanged);

    await _window.attach(startHidden: widget.startHidden);
    await _tray.attach();

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
    _auth.removeListener(_onAuthChanged);
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
