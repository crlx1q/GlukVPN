import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';
import 'state/auth_controller.dart';
import 'state/channel_controller.dart';
import 'state/vpn_controller.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';
import 'theme/tokens.dart';
import 'widgets/logo.dart';
import 'widgets/nav_bar.dart';

class GlukVpnApp extends StatefulWidget {
  const GlukVpnApp({
    super.key,
    required this.auth,
    required this.vpn,
    required this.channel,
    required this.motion,
  });

  final AuthController auth;
  final VpnController vpn;
  final ChannelController channel;
  final MotionController motion;

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
      ],
      child: MaterialApp(
        title: 'GlukVPN',
        debugShowCheckedModeBanner: false,
        theme: GlukTheme.build(),
        builder: (BuildContext context, Widget? child) {
          // Picks up "Remove animations" from accessibility settings; the whole
          // app then holds its loops still.
          widget.motion.syncWithMediaQuery(context);
          return child ?? const SizedBox.shrink();
        },
        home: const AuthGate(),
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
    // Coming back from the background: re-sync with the real tunnel and session.
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<VpnController>().refreshStatus();
    }
  }

  void _select(int index) => setState(() => _index = index);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GlukColors.bg,
      extendBody: true,
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          HomeScreen(
            onOpenServers: () => _select(1),
            onOpenProfile: () => _select(2),
          ),
          ServersScreen(onDone: () => _select(0)),
          const SettingsScreen(),
        ],
      ),
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
    );
  }
}
