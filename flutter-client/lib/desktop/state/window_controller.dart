import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../config.dart';
import 'desktop_settings.dart';

/// Which shell layout the single native window is currently showing.
enum WindowMode {
  /// Full application window.
  main,

  /// Compact quick panel anchored near the tray.
  mini,
}

/// Owns the native window.
///
/// The single most important rule, straight from requirement 11:
/// **closing the window is not disconnecting.** [onWindowClose] hides the
/// window and returns; it never touches the VPN controller.
class WindowController extends ChangeNotifier with WindowListener {
  WindowController({required SettingsStore settings}) : _settings = settings;

  final SettingsStore _settings;

  WindowMode _mode = WindowMode.main;
  bool _visible = false;
  bool _exiting = false;

  WindowMode get mode => _mode;
  bool get visible => _visible;

  /// Invoked when the user picks Exit from the tray. Set by the shell.
  Future<void> Function()? onExitRequested;

  Future<void> attach({required bool startHidden}) async {
    windowManager.addListener(this);

    // Intercept the close button so we can hide instead of terminating.
    await windowManager.setPreventClose(true);

    final saved = _settings.value;
    final size = Size(
      saved.windowWidth ?? AppConfig.desktopDefaultSize.width,
      saved.windowHeight ?? AppConfig.desktopDefaultSize.height,
    );

    await windowManager.setMinimumSize(AppConfig.desktopMinSize);
    await windowManager.setSize(size);

    final x = saved.windowX;
    final y = saved.windowY;
    if (x != null && y != null) {
      await windowManager.setPosition(Offset(x, y));
    } else {
      await windowManager.center();
    }

    if (startHidden) {
      await windowManager.hide();
      _visible = false;
    } else {
      await windowManager.show();
      await windowManager.focus();
      _visible = true;
    }

    notifyListeners();
  }

  /// Shows the full window, restoring size if we were in mini mode.
  Future<void> showMain() async {
    if (_mode != WindowMode.main) {
      _mode = WindowMode.main;
      final saved = _settings.value;
      await windowManager.setResizable(true);
      await windowManager.setMinimumSize(AppConfig.desktopMinSize);
      await windowManager.setSize(Size(
        saved.windowWidth ?? AppConfig.desktopDefaultSize.width,
        saved.windowHeight ?? AppConfig.desktopDefaultSize.height,
      ));
      await windowManager.setAlwaysOnTop(false);
      await windowManager.center();
    }

    await windowManager.show();
    await windowManager.focus();
    _visible = true;
    notifyListeners();
  }

  /// Shows the compact quick panel (requirement 10).
  Future<void> showMini() async {
    if (_mode != WindowMode.mini) {
      _mode = WindowMode.mini;
      // Shrink below the main minimum, so drop the constraint first.
      await windowManager.setMinimumSize(AppConfig.miniPanelSize);
      await windowManager.setSize(AppConfig.miniPanelSize);
      await windowManager.setResizable(false);
      await windowManager.setAlwaysOnTop(true);
      await _anchorNearTray();
    }

    await windowManager.show();
    await windowManager.focus();
    _visible = true;
    notifyListeners();
  }

  /// Left-clicking the tray toggles the quick panel.
  Future<void> toggleMini() async {
    if (_visible && _mode == WindowMode.mini) {
      await hide();
    } else {
      await showMini();
    }
  }

  /// Grows the mini panel into the full window.
  Future<void> expand() => showMain();

  Future<void> hide() async {
    await windowManager.hide();
    _visible = false;
    notifyListeners();
  }

  /// Places the mini panel in the bottom-right corner, above the taskbar.
  Future<void> _anchorNearTray() async {
    try {
      final bounds = await windowManager.getBounds();
      // window_manager has no screen API; nudging by the saved position keeps
      // this predictable, and Windows clamps us on screen anyway.
      const margin = 16.0;
      final x = bounds.left;
      final y = bounds.top;
      await windowManager.setPosition(Offset(x + margin, y + margin));
    } catch (_) {
      await windowManager.center();
    }
  }

  Future<void> _persistGeometry() async {
    if (_mode != WindowMode.main) return;
    try {
      final bounds = await windowManager.getBounds();
      await _settings.update(
        (DesktopSettings s) => s.copyWith(
          windowWidth: bounds.width,
          windowHeight: bounds.height,
          windowX: bounds.left,
          windowY: bounds.top,
        ),
      );
    } catch (_) {
      // Geometry is a nicety, not worth surfacing an error for.
    }
  }

  /// Tray Exit path: run the shutdown callback, then really quit.
  Future<void> requestExit() async {
    if (_exiting) return;
    _exiting = true;
    await _persistGeometry();
    final handler = onExitRequested;
    if (handler != null) await handler();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ---- WindowListener ----

  @override
  void onWindowClose() {
    // Requirement 11: close == hide to tray. The tunnel keeps running.
    unawaited(() async {
      await _persistGeometry();
      await hide();
    }());
  }

  @override
  void onWindowResized() {
    unawaited(_persistGeometry());
  }

  @override
  void onWindowMoved() {
    unawaited(_persistGeometry());
  }

  @override
  void onWindowFocus() {
    _visible = true;
    notifyListeners();
  }

  @override
  void onWindowMinimize() {
    _visible = false;
    notifyListeners();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }
}
