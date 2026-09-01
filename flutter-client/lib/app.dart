import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';
import 'services/connectivity_service.dart';
import 'services/update_checker.dart';
import 'state/auth_controller.dart';
import 'state/channel_controller.dart';
import 'state/vpn_controller.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';
import 'theme/tokens.dart';
import 'widgets/glass.dart';
import 'widgets/logo.dart';
import 'widgets/nav_bar.dart';
import 'widgets/page_background.dart';
import 'widgets/update_banner.dart';

class GlukVpnApp extends StatefulWidget {
  const GlukVpnApp({
    super.key,
    required this.auth,
    required this.vpn,
    required this.channel,
    required this.motion,
    required this.connectivity,
    required this.updates,
  });

  final AuthController auth;
  final VpnController vpn;
  final ChannelController channel;
  final MotionController motion;
  final ConnectivityService connectivity;
  final UpdateChecker updates;

  @override
  State<GlukVpnApp> createState() => _GlukVpnAppState();
}

class _GlukVpnAppState extends State<GlukVpnApp> {
  @override
  void initState() {
    super.initState();
    // The channel was already restored in main(); this fills in the version
    // badges in the background and restores the stored session, if any.
    widget.channel.probeAll();
    widget.auth.bootstrap();
    widget.connectivity.start();
    // First read now, then every four hours. A failed check is silent by
    // design - an older build still works, so there is nothing to report.
    widget.updates.start();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      // Type argument omitted on purpose: MultiProvider wants
      // List<SingleChildWidget>, which provider.dart does not re-export.
      providers: [
        ChangeNotifierProvider<AuthController>.value(value: widget.auth),
        ChangeNotifierProvider<VpnController>.value(value: widget.vpn),
        ChangeNotifierProvider<ChannelController>.value(value: widget.channel),
        ChangeNotifierProvider<MotionController>.value(value: widget.motion),
        ChangeNotifierProvider<ConnectivityService>.value(
          value: widget.connectivity,
        ),
        ChangeNotifierProvider<UpdateChecker>.value(value: widget.updates),
      ],
      child: MaterialApp(
        title: 'GlukVPN',
        debugShowCheckedModeBanner: false,
        theme: GlukTheme.build(),
        builder: (BuildContext context, Widget? child) {
          // Picks up "Remove animations" from accessibility settings; the whole
          // app then holds its loops still.
          widget.motion.syncWithMediaQuery(context);
          return _UpdateLayer(
            child: _ConnectivityLayer(child: child ?? const SizedBox.shrink()),
          );
        },
        home: const AuthGate(),
      ),
    );
  }
}

/// ROUND 10 (4.3): the update banner, above every screen including sign-in.
///
/// It shares the top strip with the offline banner and stands down while the
/// network is gone. "You are offline" is the more useful of the two messages,
/// and a download link is worth nothing at that exact moment.
class _UpdateLayer extends StatelessWidget {
  const _UpdateLayer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConnectivityService connectivity =
        context.watch<ConnectivityService>();
    final UpdateChecker updates = context.watch<UpdateChecker>();
    if (!connectivity.online || !updates.bannerVisible) return child;
    return Stack(
      children: <Widget>[
        child,
        const Positioned(left: 0, right: 0, top: 0, child: UpdateBanner()),
      ],
    );
  }
}

/// Puts the offline state on top of whatever is on screen.
///
/// Two shapes, on purpose:
///  * signed out (or still restoring) - a full, blocking screen, because there
///    is genuinely nothing the user can do until the network is back;
///  * signed in - a slim banner, because the last known tunnel state is still
///    worth showing and disconnecting must keep working.
///
/// Neither shape ever prints an API error, a status code or a stack trace.
class _ConnectivityLayer extends StatelessWidget {
  const _ConnectivityLayer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ConnectivityService connectivity = context.watch<ConnectivityService>();
    final AuthController auth = context.watch<AuthController>();

    if (connectivity.online) return child;

    final bool signedIn = auth.stage == AuthStage.authenticated;
    return Stack(
      children: <Widget>[
        child,
        if (signedIn)
          const Positioned(left: 0, right: 0, top: 0, child: _OfflineBanner())
        else
          const Positioned.fill(child: _OfflineScreen()),
      ],
    );
  }
}

Future<void> _retryConnection(BuildContext context) async {
  final ConnectivityService connectivity = context.read<ConnectivityService>();
  final AuthController auth = context.read<AuthController>();
  final bool back = await connectivity.check();
  if (back) await auth.resumeSession();
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final ConnectivityService connectivity = context.watch<ConnectivityService>();
    final TextTheme text = Theme.of(context).textTheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: GlassPanel(
          radius: 999,
          padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
          child: Row(
            children: <Widget>[
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: GlukColors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  connectivity.checking ? 'Reconnecting...' : "You're offline",
                  style: text.bodyMedium,
                ),
              ),
              TextButton(
                onPressed: connectivity.checking
                    ? null
                    : () => _retryConnection(context),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OfflineScreen extends StatelessWidget {
  const _OfflineScreen();

  @override
  Widget build(BuildContext context) {
    final ConnectivityService connectivity = context.watch<ConnectivityService>();
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      color: GlukColors.pageBg,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: GlukSizes.pagePadding),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: <Color>[
                        GlukColors.violet.withOpacity(0.28),
                        GlukColors.violet.withOpacity(0.02),
                      ],
                    ),
                  ),
                  child: const Icon(
                    Icons.wifi_off_rounded,
                    size: 38,
                    color: GlukColors.violetLight,
                  ),
                ),
                const SizedBox(height: 22),
                Text(
                  'No internet connection',
                  style: text.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  'Check your Wi-Fi or mobile data. Everything continues as soon '
                  'as you are back online.',
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 26),
                PrimaryPillButton(
                  label: 'Retry',
                  busy: connectivity.checking,
                  onPressed: connectivity.checking
                      ? null
                      : () => _retryConnection(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chooses between onboarding/login and the main shell, and starts VPN state
/// loading exactly once per signed-in session.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _vpnInitStarted = false;

  @override
  Widget build(BuildContext context) {
    final AuthController auth = context.watch<AuthController>();
    final MotionController motion = context.watch<MotionController>();

    if (auth.stage == AuthStage.unauthenticated) {
      // A new session (or a new channel) has to load nodes and status again.
      _vpnInitStarted = false;
    }
    if (auth.stage == AuthStage.authenticated && !_vpnInitStarted) {
      _vpnInitStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<VpnController>().init();
      });
    }

    final Widget child = switch (auth.stage) {
      AuthStage.unknown || AuthStage.restoring => const SplashView(),
      AuthStage.unauthenticated => const OnboardingScreen(),
      AuthStage.authenticated => const HomeShell(),
    };

    // `.screen` in the mock-up: opacity + a 24 px slide, 400 ms.
    return AnimatedSwitcher(
      duration: motion.transition(GlukMotion.screen),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (Widget page, Animation<double> animation) {
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.06, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
            child: page,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey<AuthStage>(auth.stage), child: child),
    );
  }
}

/// Shown while the stored session is being restored. Deliberately cheap: no
/// map, no loops, just the mark and a hairline progress bar.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: GlukColors.bg,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const GlukLogo(size: 72),
            const SizedBox(height: 20),
            Text('GlukVPN', style: text.titleLarge),
            const SizedBox(height: 6),
            Text('Securing your connection', style: text.bodySmall),
            const SizedBox(height: 26),
            const SizedBox(
              width: 120,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          ],
        ),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from the background: re-sync with the real tunnel and session,
    // and re-check reachability so a stale offline banner clears itself.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<VpnController>().refreshStatus();
      context.read<ConnectivityService>().check();
    }
  }

  void _select(int index) {
    if (_index == index) return;
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    // System back must walk the tab stack instead of leaving the app: on
    // Android 16 an unhandled back on the first route closes the process
    // straight away, which is what made Servers -> Back quit GlukVPN.
    //
    // canPop stays true on the Home tab so the predictive-back animation is
    // still native there (the user really is leaving the app), and only the
    // nested tabs intercept it.
    return PopScope(
      canPop: _index == 0,
      onPopInvoked: (bool didPop) {
        if (didPop || _index == 0) return;
        _select(0);
      },
      child: Scaffold(
        backgroundColor: GlukColors.bg,
        extendBody: true,
        // One backdrop for all three tabs: the waves sit under the map, the
        // map under the glass, and switching tabs never re-draws any of it.
        body: PageBackground(child: IndexedStack(
          index: _index,
          children: <Widget>[
            HomeScreen(
              onOpenServers: () => _select(1),
              onOpenProfile: () => _select(2),
            ),
            ServersScreen(onDone: () => _select(0)),
            const SettingsScreen(),
          ],
        )),
        bottomNavigationBar: GlukNavBar(
          index: _index,
          onChanged: _select,
          items: const <GlukNavItem>[
            GlukNavItem(
              icon: Icons.shield_outlined,
              activeIcon: Icons.shield,
              label: 'VPN',
            ),
            GlukNavItem(
              icon: Icons.public_outlined,
              activeIcon: Icons.public,
              label: 'Servers',
            ),
            GlukNavItem(
              icon: Icons.settings_outlined,
              activeIcon: Icons.settings,
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
