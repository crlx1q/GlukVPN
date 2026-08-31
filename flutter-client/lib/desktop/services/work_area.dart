import 'dart:ffi';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';

/// Win32 `RECT`.
///
/// Declared locally instead of importing `package:win32` so this file has a
/// single, stable dependency surface: the symbol is looked up by name from
/// user32.dll, which cannot drift between win32 package majors.
final class _Win32Rect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef _SystemParametersInfoNative = Int32 Function(
  Uint32 uiAction,
  Uint32 uiParam,
  Pointer<_Win32Rect> pvParam,
  Uint32 fWinIni,
);
typedef _SystemParametersInfoDart = int Function(
  int uiAction,
  int uiParam,
  Pointer<_Win32Rect> pvParam,
  int fWinIni,
);

/// Resolves the usable desktop rectangle, i.e. the screen minus the taskbar.
///
/// Needed to anchor the tray quick panel just above the notification area the
/// way native Windows utilities do. `window_manager` exposes no screen API, and
/// the previous implementation simply nudged the window by +16/+16 from
/// wherever it happened to be, which put the panel in the middle of the screen.
class WorkArea {
  const WorkArea._();

  static const int _spiGetWorkArea = 0x0030;

  static _SystemParametersInfoDart? _fn;
  static bool _lookupFailed = false;

  /// Primary monitor work area in physical pixels, or null when unavailable.
  static Rect? primary() {
    if (!Platform.isWindows || _lookupFailed) return null;

    final _SystemParametersInfoDart? fn = _resolve();
    if (fn == null) return null;

    final Pointer<_Win32Rect> rect = calloc<_Win32Rect>();
    try {
      final int ok = fn(_spiGetWorkArea, 0, rect, 0);
      if (ok == 0) return null;

      final _Win32Rect r = rect.ref;
      if (r.right <= r.left || r.bottom <= r.top) return null;

      return Rect.fromLTRB(
        r.left.toDouble(),
        r.top.toDouble(),
        r.right.toDouble(),
        r.bottom.toDouble(),
      );
    } catch (_) {
      return null;
    } finally {
      calloc.free(rect);
    }
  }

  /// Top-left position for a [width] x [height] panel tucked into the corner
  /// nearest the tray, with [margin] breathing room.
  ///
  /// Windows puts the notification area at the end of the taskbar, so the
  /// bottom-right of the work area is correct for the default layout and still
  /// sane for a top or left taskbar (the panel simply hugs that corner).
  static Rect? trayAnchoredBounds({
    required double width,
    required double height,
    double margin = 12,
    double devicePixelRatio = 1.0,
  }) {
    final Rect? area = primary();
    if (area == null) return null;

    final double scale = devicePixelRatio <= 0 ? 1.0 : devicePixelRatio;
    // window_manager works in logical pixels; SPI_GETWORKAREA is physical.
    final double logicalRight = area.right / scale;
    final double logicalBottom = area.bottom / scale;
    final double logicalLeft = area.left / scale;
    final double logicalTop = area.top / scale;

    double x = logicalRight - width - margin;
    double y = logicalBottom - height - margin;

    if (x < logicalLeft) x = logicalLeft + margin;
    if (y < logicalTop) y = logicalTop + margin;

    return Rect.fromLTWH(x, y, width, height);
  }

  static _SystemParametersInfoDart? _resolve() {
    final _SystemParametersInfoDart? cached = _fn;
    if (cached != null) return cached;
    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final _SystemParametersInfoDart fn = user32.lookupFunction<
          _SystemParametersInfoNative,
          _SystemParametersInfoDart>('SystemParametersInfoW');
      _fn = fn;
      return fn;
    } catch (_) {
      _lookupFailed = true;
      return null;
    }
  }
}
