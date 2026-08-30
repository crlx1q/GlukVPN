import 'package:flutter/material.dart';

import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/page_background.dart';
import '../i18n/desktop_strings.dart';
import '../state/desktop_settings.dart';
import '../state/desktop_vpn_controller.dart';
import '../state/tray_controller.dart';
import '../state/window_controller.dart';
import '../widgets/side_nav.dart';
import '../widgets/window_title_bar.dart';
import 'desktop_home_screen.dart';
import 'desktop_servers_screen.dart';
import 'desktop_settings_screen.dart';
import 'desktop_stats_screen.dart';
import 'mini_panel.dart';

/// Root of the authenticated desktop UI.
///
/// Switches between the full window layout and the compact tray panel based
/// on [WindowController.mode], and owns the navigation rail.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.vpn,
    required this.auth,
    required this.settings,
    required this.window,
    required this.tray,
    required this.strings,
    required this.onLanguageChanged,
  });

  final DesktopVpnController vpn;
  final AuthController auth;
  final SettingsStore settings;
  final WindowController window;
  final TrayController tray;
  final DesktopStrings strings;
  final ValueChanged<String> onLanguageChanged;

  @override
  State<DesktopShell> createState() => DesktopShellState();
}

class DesktopShellState extends State<DesktopShell> {
  static const int _home = 0;
  static const int _servers = 1;
  static const int _stats = 2;
  static const int _settingsTab = 3;

  int _index = _home;

  @override
  void initState() {
    super.initState();
    // Let the tray jump straight to the settings tab.
    widget.tray.onOpenSettings = openSettings;
  }

  /// Public so the tray controller can drive navigation.
  void openSettings() {
    if (!mounted) return;
    setState(() => _index = _settingsTab);
  }

  void openServers() {
    if (!mounted) return;
    setState(() => _index = _servers);
  }

  bool get _reduceMotion {
    final s = widget.settings.value;
    return s.reduceMotion || !s.animationsEnabled;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the VPN, window mode or settings change.
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.vpn,
        widget.window,
        widget.settings,
        widget.auth,
      ]),
      builder: (BuildContext context, Widget? child) {
        if (widget.window.mode == WindowMode.mini) {
          return MiniPanel(
            vpn: widget.vpn,
            strings: widget.strings,
            reduceMotion: _reduceMotion,
            onExpand: () => widget.window.expand(),
            onHide: () => widget.window.hide(),
          );
        }
        return _buildMain(context);
      },
    );
  }

  Widget _buildMain(BuildContext context) {
    final s = widget.strings;

    return ColoredBox(
      color: GlukColors.pageBg,
      child: Stack(
        children: <Widget>[
          // Shared ambient background from the mobile design system.
          const Positioned.fill(child: PageBackground()),

          Column(
            children: <Widget>[
              const WindowTitleBar(),
              Expanded(
                child: Row(
                  children: <Widget>[
                    SideNav(
                      index: _index,
                      onChanged: (int i) => setState(() => _index = i),
                      items: <SideNavItem>[
                        SideNavItem(
                          icon: Icons.shield_moon_outlined,
                          label: s.navHome,
                        ),
                        SideNavItem(
                          icon: Icons.public_rounded,
                          label: s.navServers,
                        ),
                        SideNavItem(
                          icon: Icons.insights_rounded,
                          label: s.navStats,
                        ),
                        SideNavItem(
                          icon: Icons.tune_rounded,
                          label: s.navSettings,
                        ),
                      ],
                      footer: _StatusDot(vpn: widget.vpn),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: GlukMotion.screen,
                        switchInCurve: Curves.easeOutCubic,
                        transitionBuilder:
                            (Widget child, Animation<double> anim) {
                          return FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.015, 0),
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey<int>(_index),
                          child: _page(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _page() {
    switch (_index) {
      case _servers:
        return DesktopServersScreen(
          vpn: widget.vpn,
          strings: widget.strings,
        );
      case _stats:
        return DesktopStatsScreen(
          usage: widget.vpn.usage,
          strings: widget.strings,
        );
      case _settingsTab:
        return DesktopSettingsScreen(
          settings: widget.settings,
          vpn: widget.vpn,
          auth: widget.auth,
          strings: widget.strings,
          onLanguageChanged: widget.onLanguageChanged,
        );
      case _home:
      default:
        return DesktopHomeScreen(
          vpn: widget.vpn,
          auth: widget.auth,
          strings: widget.strings,
          reduceMotion: _reduceMotion,
          onOpenServers: openServers,
        );
    }
  }
}

/// Small always-visible tunnel indicator at the bottom of the rail.
class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.vpn});

  final DesktopVpnController vpn;

  @override
  Widget build(BuildContext context) {
    final phase = vpn.phase;
    final color = phase.isConnected
        ? GlukColors.connected
        : phase.isError
            ? GlukColors.danger
            : phase.isBusy
                ? GlukColors.amber
                : GlukColors.text2;

    return Tooltip(
      message: phase.labelKey,
      child: AnimatedContainer(
        duration: GlukMotion.screen,
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: 0.55),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}
