import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../../utils/format.dart';
import '../i18n/desktop_strings.dart';
import '../logic/connection_phase.dart';
import 'desktop_vpn_controller.dart';
import 'window_controller.dart';

/// System tray icon and context menu (requirement 9).
///
/// The icon reflects the *verified* tunnel phase, so it never shows green
/// while the tunnel is still coming up.
class TrayController with TrayListener {
  TrayController({
    required DesktopVpnController vpn,
    required WindowController window,
    required DesktopStrings strings,
  })  : _vpn = vpn,
        _window = window,
        _strings = strings;

  final DesktopVpnController _vpn;
  final WindowController _window;
  DesktopStrings _strings;

  String? _lastIcon;
  String? _lastSignature;
  bool _attached = false;

  /// Set by the shell so the tray can jump straight to Settings.
  void Function()? onOpenSettings;

  Future<void> attach() async {
    if (_attached) return;
    _attached = true;

    trayManager.addListener(this);
    await _applyIcon(force: true);
    await trayManager.setToolTip('GlukVPN');
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
    final icon = 'assets/tray/${_vpn.phase.trayIconName}.ico';
    if (!force && icon == _lastIcon) return;
    _lastIcon = icon;
    try {
      await trayManager.setIcon(icon);
      await trayManager.setToolTip(_tooltip());
    } catch (_) {
      // A missing icon must never take down the app.
    }
  }

  String _tooltip() {
    final status = _strings.phaseLabel(_vpn.phase);
    final node = _vpn.selectedNode;
    if (node == null) return 'GlukVPN — $status';
    return 'GlukVPN — $status · ${node.displayTitle}';
  }

  /// Rebuilds only when something visible actually changed; Windows flickers
  /// the menu otherwise.
  Future<void> _rebuildMenu({bool force = false}) async {
    final signature = _signature();
    if (!force && signature == _lastSignature) return;
    _lastSignature = signature;

    final phase = _vpn.phase;
    final node = _vpn.selectedNode;
    final ping = _vpn.currentPingMs;

    final menu = Menu(
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
          label: '${_strings.trayServer}: '
              '${node?.displayTitle ?? _strings.trayAutoServer}',
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
              '↓ ${formatBytes(_vpn.rxBytes)}  ↑ ${formatBytes(_vpn.txBytes)}',
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
    } catch (_) {
      // Ignore transient shell failures.
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
    // Left click opens the compact quick panel (requirement 10).
    unawaited(_window.toggleMini());
  }

  @override
  void onTrayIconRightMouseDown() {
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
    _vpn.removeListener(_onVpnChanged);
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // Nothing useful to do during shutdown.
    }
  }
}
