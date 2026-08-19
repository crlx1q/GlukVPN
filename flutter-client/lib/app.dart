import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';
import 'state/auth_controller.dart';
import 'state/vpn_controller.dart';

const Color kAccent = Color(0xFF3DDC97);
const Color kDanger = Color(0xFFFF6B6B);
const Color kBackground = Color(0xFF0B0F14);
const Color kSurface = Color(0xFF151B23);

ThemeData buildGlukTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: kAccent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: kAccent,
    secondary: kAccent,
    surface: kSurface,
    error: kDanger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBackground,
    appBarTheme: const AppBarTheme(
      backgroundColor: kBackground,
      elevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardTheme(
      color: kSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kSurface,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      labelTextStyle: const WidgetStatePropertyAll<TextStyle>(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

class GlukVpnApp extends StatefulWidget {
  const GlukVpnApp({super.key, required this.auth, required this.vpn});

  final AuthController auth;
  final VpnController vpn;

  @override
  State<GlukVpnApp> createState() => _GlukVpnAppState();
}

class _GlukVpnAppState extends State<GlukVpnApp> {
  @override
  void initState() {
    super.initState();
    // Restores a stored session, if any, before the first frame settles.
    widget.auth.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthController>.value(value: widget.auth),
        ChangeNotifierProvider<VpnController>.value(value: widget.vpn),
      ],
      child: MaterialApp(
        title: 'GlukVPN',
        debugShowCheckedModeBanner: false,
        theme: buildGlukTheme(),
        home: const AuthGate(),
      ),
    );
  }
}

/// Chooses between the login screen and the main shell, and starts VPN state
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

    switch (auth.stage) {
      case AuthStage.unknown:
      case AuthStage.restoring:
        return const _SplashView();
      case AuthStage.unauthenticated:
        _vpnInitStarted = false;
        return const LoginScreen();
      case AuthStage.authenticated:
        if (!_vpnInitStarted) {
          _vpnInitStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            context.read<VpnController>().init();
          });
        }
        return const HomeShell();
    }
  }
}

class _SplashView extends StatelessWidget {
  const _SplashView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(Icons.shield_outlined, size: 56, color: kAccent),
            SizedBox(height: 18),
            Text('GlukVPN', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            SizedBox(height: 22),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const <Widget>[HomeScreen(), ServersScreen(), SettingsScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (int value) => setState(() => _index = value),
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: 'VPN',
          ),
          NavigationDestination(
            icon: Icon(Icons.public_outlined),
            selectedIcon: Icon(Icons.public),
            label: 'Servers',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
