import 'package:flutter/material.dart';

import '../../state/auth_controller.dart';
import '../../theme/tokens.dart';
import '../../widgets/page_background.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../services/power_monitor.dart';
import '../state/desktop_settings.dart';
import '../state/desktop_vpn_controller.dart';
import '../state/tray_controller.dart';
import '../state/window_controller.dart';
import '../theme/desktop_theme.dart';
import '../widgets/desktop_sidebar.dart';
import '../widgets/window_title_bar.dart';
import 'desktop_account_screen.dart';
import 'desktop_home_screen.dart';
import 'desktop_servers_screen.dart';
import 'desktop_settings_screen.dart';
import 'desktop_stats_screen.dart';
import 'mini_panel.dart';

/// Root of the authenticated desktop UI.
///
/// Switches between the full window layout and the compact tray panel based on
/// [WindowController.mode], and owns navigation.
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.vpn,
    required this.auth,
    required this.settings,
    required this.window,
    required this.tray,
    required this.power,
    required this.strings,
    required this.onLanguageChanged,
  });

  final DesktopVpnController vpn;
  final AuthController auth;
  final SettingsStore settings;
  final WindowController window;
  final TrayController tray;
  final PowerMonitor power;
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

  /// Deliberately past the end of the sidebar's item list: Account is reached
  /// by clicking the account card at the bottom of the rail, not by a fifth nav
  /// pill. The sidebar highlights nothing while this page is open, which is
  /// correct - the card itself is the affordance.
  static const int _accountTab = 4;

  int _index = _home;

  @override
  void initState() {
    super.initState();
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

  /// ROUND 6: the account card used to open Settings and leave the user to find
  /// the Account section at the bottom of six others. It now opens the account.
  void openAccount() {
    if (!mounted) return;
    setState(() => _index = _accountTab);
  }

  /// One switch, plus the laptop's own opinion.
  ///
  /// Requirement 15, as restated by the user: a single Animations toggle, and
  /// motion stands down on its own when running on battery or in Windows
  /// battery saver. The VPN itself is never affected.
  bool get _reduceMotion {
    final DesktopSettings s = widget.settings.value;
    return s.motionDisabled(onBattery: widget.power.shouldReduceMotion);
  }

  Color get _statusColor {
    final ConnectionPhase phase = widget.vpn.phase;
    if (phase.isConnected) return GlukColors.connected;
    if (phase.isError) return GlukColors.danger;
    if (phase.isBusy) return GlukColors.amber;
    return GlukColors.text2;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.vpn,
        widget.window,
        widget.settings,
        widget.auth,
        widget.power,
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
    final DesktopStrings s = widget.strings;
    final String name = widget.auth.user?.username ??
        (s.isRussian ? 'Аккаунт' : 'Account');

    return ColoredBox(
      color: GlukColors.pageBg,
      child: Stack(
        children: <Widget>[
          const Positioned.fill(child: PageBackground()),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DesktopSidebar(
                index: _index,
                onChanged: (int i) => setState(() => _index = i),
                userName: name,
                userIdLabel: widget.auth.user?.publicIdLabel,
                statusColor: _statusColor,
                onAccountTap: openAccount,
                items: <SidebarItem>[
                  SidebarItem(
                    icon: Icons.vpn_lock_rounded,
                    label: s.navHome,
                  ),
                  SidebarItem(
                    icon: Icons.public_rounded,
                    label: s.navServers,
                  ),
                  SidebarItem(
                    icon: Icons.insights_rounded,
                    label: s.navStats,
                  ),
                  SidebarItem(
                    icon: Icons.tune_rounded,
                    label: s.navSettings,
                  ),
                ],
              ),
              Expanded(
                child: Column(
                  children: <Widget>[
                    // No maximise button: the window is a fixed panel.
                  const WindowTitleBar(showMaximize: false),
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
                                begin: const Offset(0.012, 0),
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
        return Padding(
          padding: const EdgeInsets.only(
            right: DesktopTokens.pagePadding,
            bottom: DesktopTokens.pagePadding,
          ),
          child: DesktopServersScreen(
            vpn: widget.vpn,
            strings: widget.strings,
          ),
        );
      case _stats:
        return Padding(
          padding: const EdgeInsets.only(
            right: DesktopTokens.pagePadding,
            bottom: DesktopTokens.pagePadding,
          ),
          child: DesktopStatsScreen(
            usage: widget.vpn.usage,
            strings: widget.strings,
          ),
        );
      case _accountTab:
        return Padding(
          padding: const EdgeInsets.only(
            right: DesktopTokens.pagePadding,
            bottom: DesktopTokens.pagePadding,
          ),
          child: DesktopAccountScreen(
            auth: widget.auth,
            vpn: widget.vpn,
            strings: widget.strings,
          ),
        );
      case _settingsTab:
        return Padding(
          padding: const EdgeInsets.only(
            right: DesktopTokens.pagePadding,
            bottom: DesktopTokens.pagePadding,
          ),
          child: DesktopSettingsScreen(
            settings: widget.settings,
            vpn: widget.vpn,
            auth: widget.auth,
            strings: widget.strings,
            onLanguageChanged: widget.onLanguageChanged,
          ),
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
