import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import '../../config.dart';
import '../services/desktop_log.dart';
import '../services/window_fx.dart';
import '../services/work_area.dart';
import 'desktop_settings.dart';

/// Which shell layout the single native window is currently showing.
enum WindowMode {
  /// Full application window.
  main,

  /// Compact quick panel anchored above the notification area.
  mini,
}

/// Owns the native window.
///
/// The single most important rule, straight from requirement 11:
/// **closing the window is not disconnecting.** [onWindowClose] hides the
/// window and returns; it never touches the VPN controller.
///
/// Tray behaviour implemented here:
///   * one left click  -> [toggleMini], a small panel pinned to the corner
///     nearest the tray, exactly like a native Windows utility panel,
///   * double left click -> [openFromTray], the full window,
///   * clicking elsewhere dismisses the mini panel (focus loss).
class WindowController extends ChangeNotifier with WindowListener {
  WindowController({required SettingsStore settings}) : _settings = settings;

  final SettingsStore _settings;

  WindowMode _mode = WindowMode.main;
  bool _visible = false;
  bool _exiting = false;

  /// Suppresses the auto-dismiss during the frames right after showing the
  /// mini panel, when Windows has not handed us focus yet.
  DateTime? _miniShownAt;

  WindowMode get mode => _mode;
  bool get visible => _visible;

  /// Invoked when the user picks Exit from the tray. Set by the shell.
  Future<void> Function()? onExitRequested;

  Future<void> attach({required bool startHidden}) async {
    windowManager.addListener(this);

    // Intercept the close button so we can hide instead of terminating.
    await windowManager.setPreventClose(true);

    final DesktopSettings saved = _settings.value;

    // Fixed panel: one size only. The stored width and height are ignored on
    // purpose, otherwise the old oversized geometry would come straight back.
    const Size size = AppConfig.desktopDefaultSize;

    await windowManager.setMinimumSize(AppConfig.desktopMinSize);
    await windowManager.setMaximumSize(AppConfig.desktopDefaultSize);
    await windowManager.setSize(size);
    await windowManager.setResizable(false);

    final double? x = saved.windowX;
    final double? y = saved.windowY;
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

    // Dark title bar, no Windows 11 light border, DWM-owned rounding.
    WindowFx.applyWindowChrome();
    // Win32 popup menus follow the process theme, so it has to be set before
    // the tray menu can ever be opened.
    WindowFx.applySystemMenuTheme();

    notifyListeners();
  }

  /// Shows the full window, restoring size if we were in mini mode.
  Future<void> showMain() async {
    if (_mode != WindowMode.main) {
      _mode = WindowMode.main;
      final DesktopSettings saved = _settings.value;
      try {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setMinimumSize(AppConfig.desktopMinSize);
        await windowManager.setMaximumSize(AppConfig.desktopDefaultSize);
        await windowManager.setSize(AppConfig.desktopDefaultSize);
        // Stays false: returning from the tray panel must not hand the main
        // window a resize grip again.
        await windowManager.setResizable(false);

        final double? x = saved.windowX;
        final double? y = saved.windowY;
        if (x != null && y != null) {
          await windowManager.setPosition(Offset(x, y));
        } else {
          await windowManager.center();
        }
      } catch (e) {
        dlog.warn('window', 'restore to main failed: $e');
      }
    }

    await _surface();
    WindowFx.applyWindowChrome();
    _visible = true;
    notifyListeners();
  }

  /// Puts the native window on screen whatever state Windows left it in.
  ///
  /// ROUND 10 (1.2). `show()` on its own is not enough, and that is exactly
  /// how the window used to get stuck:
  ///
  ///   * a window the user minimised stays minimised - `show()` does not undo
  ///     `SW_MINIMIZE`, only `restore()` does,
  ///   * `focus()` is refused outright when the foreground window belongs to
  ///     another process, so the tray click "worked", `_visible` flipped to
  ///     true, and nothing appeared.
  ///
  /// Every path that is supposed to reveal the window goes through here.
  Future<void> _surface() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
    } catch (e) {
      dlog.warn('window', 'restore failed: $e');
    }

    await windowManager.show();
    await windowManager.focus();

    // Windows only hands the foreground to the process that already owns it.
    // A brief topmost flip is the standard way to ask for it without the
    // AttachThreadInput hack, and the mini panel is topmost anyway.
    if (_mode == WindowMode.main) {
      try {
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setAlwaysOnTop(false);
      } catch (_) {
        // Cosmetic. It must never stop the window from appearing.
      }
    }
  }

  /// Double left click on the tray icon.
  Future<void> openFromTray() async {
    dlog.write('tray', 'double click -> full window');
    await showMain();
  }

  /// A second copy of GlukVPN was launched and asked us to come forward.
  ///
  /// Always the full window: the person double-clicked the desktop shortcut,
  /// so a 320 px tray panel is not what they asked for.
  Future<void> surfaceForSecondInstance() async {
    dlog.write('single', 'show request from a second instance');
    await showMain();
  }

  /// Shows the compact quick panel (requirement 10).
  Future<void> showMini() async {
    final Size panel = AppConfig.miniPanelSize;

    if (_mode != WindowMode.mini) {
      _mode = WindowMode.mini;
      try {
        // Shrink below the main minimum, so drop the constraint first.
        await windowManager.setMinimumSize(panel);
        await windowManager.setSize(panel);
        await windowManager.setResizable(false);
        await windowManager.setAlwaysOnTop(true);
        // A tray panel does not belong on the taskbar.
        await windowManager.setSkipTaskbar(true);
      } catch (e) {
        dlog.warn('window', 'mini resize failed: $e');
      }
    }

    await _anchorNearTray(panel);

    _miniShownAt = DateTime.now();
    await _surface();
    // Small DWM radius and no native border: the panel is painted flat, so
    // there is exactly one rounded shape instead of a widget radius fighting
    // the window's own border. That double edge is what glowed at the sides.
    WindowFx.applyPanelChrome();
    _visible = true;
    notifyListeners();
  }

  /// Single left click on the tray icon.
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

  /// Pins the mini panel to the work-area corner nearest the notification
  /// area, a few pixels above the taskbar.
  Future<void> _anchorNearTray(Size panel) async {
    try {
      final Rect? bounds = WorkArea.trayAnchoredBounds(
        width: panel.width,
        height: panel.height,
        margin: 12,
        devicePixelRatio: _devicePixelRatio(),
      );

      if (bounds == null) {
        dlog.warn('window', 'work area unavailable, centring mini panel');
        await windowManager.center();
        return;
      }

      await windowManager.setPosition(Offset(bounds.left, bounds.top));
    } catch (e) {
      dlog.warn('window', 'anchor failed: $e');
      await windowManager.center();
    }
  }

  double _devicePixelRatio() {
    try {
      final Iterable<FlutterView> views = PlatformDispatcher.instance.views;
      if (views.isNotEmpty) return views.first.devicePixelRatio;
    } catch (_) {
      // Fall through to 1.0 on any platform surprise.
    }
    return 1.0;
  }

  Future<void> _persistGeometry() async {
    if (_mode != WindowMode.main) return;
    try {
      final bool isMinimized = await windowManager.isMinimized();
      if (isMinimized) return;
      final Rect bounds = await windowManager.getBounds();
      if (bounds.left < -10000 || bounds.top < -10000) return;
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
    final Future<void> Function()? handler = onExitRequested;
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
  void onWindowBlur() {
    // Native tray panels close when they lose focus. The main window must not.
    if (_mode != WindowMode.mini || !_visible || _exiting) return;

    final DateTime? shown = _miniShownAt;
    if (shown != null &&
        DateTime.now().difference(shown) < const Duration(milliseconds: 400)) {
      return;
    }

    unawaited(hide());
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
