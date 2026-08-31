import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../models/models.dart';
import '../../utils/format.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import '../logic/node_selector.dart';
import '../services/desktop_log.dart';
import '../services/window_fx.dart';
import 'desktop_vpn_controller.dart';
import 'window_controller.dart';

/// System tray icon and context menu (requirement 9).
///
/// Mouse mapping, as requested:
///   * right click        -> the context menu below,
///   * single left click   -> the compact quick panel near the tray,
///   * double left click   -> the full application window.
///
/// Windows delivers one `mouseDown` per physical click with no notion of a
/// double click, so the two are told apart with a short debounce: the first
/// click schedules the panel, and a second click inside the window cancels it
/// and opens the main window instead.
///
/// The icon reflects the *verified* tunnel phase, so it never shows green while
/// the tunnel is still coming up. The four .ico files are logo-based and carry
/// a state-coloured glow (violet idle, amber connecting, green connected, red
/// error) - see desktop/packaging/make-icons.ps1.
class TrayController with TrayListener {
  TrayController({
    required DesktopVpnController vpn,
    required WindowController window,
    required DesktopStrings strings,
  })  : _vpn = vpn,
        _window = window,
        _strings = strings;

  /// How long to wait for a possible second click.
  static const Duration doubleClickWindow = Duration(milliseconds: 280);

  final DesktopVpnController _vpn;
  final WindowController _window;
  DesktopStrings _strings;

  String? _lastIcon;
  String? _lastSignature;
  bool _attached = false;

  Timer? _clickTimer;
  int _pendingClicks = 0;

  /// Set by the shell so the tray can jump straight to Settings.
  void Function()? onOpenSettings;

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;

    trayManager.addListener(this);
    // The context menu is a real Win32 menu, so it follows the *process*
    // theme rather than the app's colours. Without this it is bright white on
    // a dark desktop, which is exactly what was reported.
    WindowFx.applySystemMenuTheme();
    await _applyIcon(force: true);
    await _rebuildMenu(force: true);

    _vpn.addListener(_onVpnChanged);
  }

  void updateStrings(DesktopStrings strings) {
    _strings = strings;
    unawaited(_rebuildMenu(force: true));
  }

  void _onVpnChanged() {
    unawaited(_applyIcon());
    unawaited(_rebuildMenu());
  }

  // -------------------------------------------------------------------

  Future<void> _applyIcon({bool force = false}) async {
    final String icon = 'assets/tray/${_vpn.phase.trayIconName}.ico';
    if (!force && icon == _lastIcon) return;
    _lastIcon = icon;
    try {
      await trayManager.setIcon(icon);
      await trayManager.setToolTip(_tooltip());
    } catch (e) {
      // A missing icon must never take down the app.
      dlog.warn('tray', 'setIcon($icon) failed: $e');
    }
  }

  String _tooltip() {
    final String status = _strings.phaseLabel(_vpn.phase);
    final VpnNodeInfo? node = _vpn.selectedNode;
    if (node == null) return 'GlukVPN \u2014 $status';
    // Never the node handle: publicNodeLocation only ever returns geography,
    // now as "Frankfurt, Германия" rather than a bare country code.
    final String server = publicNodeLocation(
      node,
      russian: _strings.isRussian,
      fallback: _strings.trayAutoServer,
    );
    return 'GlukVPN \u2014 $status \u00b7 $server';
  }

  /// Rebuilds only when something visible actually changed; Windows flickers
  /// the menu otherwise.
  Future<void> _rebuildMenu({bool force = false}) async {
    final String signature = _signature();
    if (!force && signature == _lastSignature) return;
    _lastSignature = signature;

    final ConnectionPhase phase = _vpn.phase;
    final int? ping = _vpn.currentPingMs;
    final VpnNodeInfo? selected = _vpn.selectedNode;
    final String server = selected == null
        ? _strings.trayAutoServer
        : publicNodeLocation(
            selected,
            russian: _strings.isRussian,
            fallback: _strings.trayAutoServer,
          );

    final Menu menu = Menu(
      items: <MenuItem>[
        MenuItem(key: 'title', label: 'GlukVPN', disabled: true),
        MenuItem.separator(),
        MenuItem(
          key: 'connect',
          label: _strings.trayConnect,
          disabled: !phase.connectEnabled || phase.isConnected,
        ),
        MenuItem(
          key: 'disconnect',
          label: _strings.trayDisconnect,
          disabled: !phase.isConnected && phase != ConnectionPhase.connecting,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'server',
          label: '${_strings.trayServer}: $server',
          disabled: true,
        ),
        MenuItem(
          key: 'ping',
          label: '${_strings.trayPing}: '
              '${ping == null ? _strings.dash : formatPing(ping)}',
          disabled: true,
        ),
        MenuItem(
          key: 'traffic',
          label: '${_strings.trayTraffic}: '
              '\u2193 ${formatBytes(_vpn.rxBytes)}  '
              '\u2191 ${formatBytes(_vpn.txBytes)}',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(key: 'open', label: _strings.trayOpen),
        MenuItem(key: 'settings', label: _strings.traySettings),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: _strings.trayExit),
      ],
    );

    try {
      await trayManager.setContextMenu(menu);
    } catch (e) {
      dlog.warn('tray', 'setContextMenu failed: $e');
    }
  }

  String _signature() => <Object?>[
        _vpn.phase,
        _vpn.selectedNode?.id,
        _vpn.currentPingMs,
        _vpn.rxBytes >> 16, // only refresh every ~64 KiB
        _vpn.txBytes >> 16,
      ].join('|');

  // ---- TrayListener ----

  @override
  void onTrayIconMouseDown() {
    _pendingClicks++;

    if (_pendingClicks >= 2) {
      // Second click inside the window: this is a double click.
      _clickTimer?.cancel();
      _clickTimer = null;
      _pendingClicks = 0;
      unawaited(_window.openFromTray());
      return;
    }

    _clickTimer?.cancel();
    _clickTimer = Timer(doubleClickWindow, () {
      _clickTimer = null;
      _pendingClicks = 0;
      dlog.write('tray', 'single click -> mini panel');
      unawaited(_window.toggleMini());
    });
  }

  @override
  void onTrayIconRightMouseDown() {
    // Re-read the system theme first, so switching Windows to dark mode is
    // picked up without restarting GlukVPN.
    WindowFx.refreshMenuTheme();
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'connect':
        unawaited(_vpn.connect());
        break;
      case 'disconnect':
        unawaited(_vpn.disconnect());
        break;
      case 'open':
        unawaited(_window.showMain());
        break;
      case 'settings':
        unawaited(() async {
          await _window.showMain();
          onOpenSettings?.call();
        }());
        break;
      case 'exit':
        unawaited(_window.requestExit());
        break;
    }
  }

  Future<void> dispose() async {
    _clickTimer?.cancel();
    _vpn.removeListener(_onVpnChanged);
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // Nothing useful to do during shutdown.
    }
  }
}
