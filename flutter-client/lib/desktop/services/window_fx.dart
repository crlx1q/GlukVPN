import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'desktop_log.dart';

/// Native window polish that Flutter and window_manager do not expose.
///
/// Three concrete problems are fixed here, all reported after the first
/// release:
///
///  1. **Glowing edges around the tray panel.** Windows 11 paints a light 1 px
///     border around every top-level window. On a borderless dark panel that
///     border reads as a glow along the sides. [applyPanelChrome] sets
///     DWMWA_BORDER_COLOR to DWMWA_COLOR_NONE so there is nothing to glow.
///  2. **Mismatched corners.** DWM rounds the window while the widget tree
///     rounds the content, and the two radii never agree, which leaves stray
///     pixels in the corners. We ask DWM for the rounding and draw square
///     content underneath, so there is exactly one rounded shape.
///  3. **A bright white tray context menu.** tray_manager hands the menu to
///     Win32, and Win32 menus follow the *process* theme, not the app's colours.
///     [applySystemMenuTheme] switches the process to the same mode Windows
///     itself is in, so the menu is dark on a dark system and light on a light
///     one.
///
/// Everything here is best-effort: any failure is logged and ignored. A
/// cosmetic tweak must never be able to take down the client.
class WindowFx {
  WindowFx._();

  // ---- DWM attributes ----
  static const int _dwmUseImmersiveDarkMode = 20;
  static const int _dwmWindowCornerPreference = 33;
  static const int _dwmBorderColour = 34;

  // DWM_WINDOW_CORNER_PREFERENCE
  static const int cornerDefault = 0;
  static const int cornerDoNotRound = 1;
  static const int cornerRound = 2;
  static const int cornerRoundSmall = 3;

  /// DWMWA_COLOR_NONE: "do not draw this border at all".
  static const int _colourNone = 0xFFFFFFFE;

  // PreferredAppMode (uxtheme.dll, ordinal 135)
  static const int _appModeDefault = 0;
  static const int _appModeForceDark = 2;
  static const int _appModeForceLight = 3;

  static const int _hkeyCurrentUser = 0x80000001;
  static const int _rrfRegDword = 0x00000018;

  static bool _menuThemeApplied = false;
  static int? _cachedHwnd;

  /// Handle of the Flutter window. Cached, because FindWindow is a search.
  static int? hwnd() {
    final int? cached = _cachedHwnd;
    if (cached != null && cached != 0) return cached;

    return using<int?>((Arena arena) {
      try {
        final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
        final _FindWindowW find = user32
            .lookupFunction<_FindWindowWNative, _FindWindowW>('FindWindowW');

        // Every Flutter Windows runner registers this window class.
        final Pointer<Utf16> cls =
            'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16(allocator: arena);
        final int handle = find(cls, nullptr);
        if (handle != 0) {
          _cachedHwnd = handle;
          return handle;
        }
      } catch (e) {
        dlog.warn('windowfx', 'FindWindowW failed: $e');
      }
      return null;
    });
  }

  static void _setAttribute(int handle, int attribute, int value) {
    using((Arena arena) {
      final DynamicLibrary dwm = DynamicLibrary.open('dwmapi.dll');
      final _DwmSetWindowAttribute set = dwm.lookupFunction<
          _DwmSetWindowAttributeNative,
          _DwmSetWindowAttribute>('DwmSetWindowAttribute');

      final Pointer<Uint32> buffer = arena<Uint32>();
      buffer.value = value;
      set(handle, attribute, buffer.cast<Void>(), sizeOf<Uint32>());
    });
  }

  /// Dark title bar + no native border. Safe to call more than once.
  static void applyWindowChrome({int corner = cornerRound}) {
    final int? handle = hwnd();
    if (handle == null) return;
    try {
      _setAttribute(handle, _dwmUseImmersiveDarkMode, 1);
      _setAttribute(handle, _dwmBorderColour, _colourNone);
      _setAttribute(handle, _dwmWindowCornerPreference, corner);
    } catch (e) {
      dlog.warn('windowfx', 'window chrome failed: $e');
    }
  }

  /// Chrome for the compact tray panel: small radius, no border.
  static void applyPanelChrome() =>
      applyWindowChrome(corner: cornerRoundSmall);

  /// True when Windows is running its dark app theme.
  static bool systemPrefersDark() {
    return using<bool>((Arena arena) {
      try {
        final DynamicLibrary advapi = DynamicLibrary.open('advapi32.dll');
        final _RegGetValueW get = advapi
            .lookupFunction<_RegGetValueWNative, _RegGetValueW>('RegGetValueW');

        final Pointer<Uint32> data = arena<Uint32>();
        final Pointer<Uint32> size = arena<Uint32>();
        size.value = sizeOf<Uint32>();

        final int status = get(
          _hkeyCurrentUser,
          r'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
              .toNativeUtf16(allocator: arena),
          'AppsUseLightTheme'.toNativeUtf16(allocator: arena),
          _rrfRegDword,
          nullptr,
          data.cast<Void>(),
          size,
        );

        // 0 == "apps use the dark theme". A missing value means light.
        if (status == 0) return data.value == 0;
      } catch (e) {
        dlog.warn('windowfx', 'theme probe failed: $e');
      }
      // Windows 11 ships light by default; guessing dark would be worse.
      return false;
    });
  }

  /// Makes Win32 popup menus (the tray context menu) follow the system theme.
  ///
  /// SetPreferredAppMode and FlushMenuThemes are exported by uxtheme.dll by
  /// ordinal only, so they are resolved through GetProcAddress with the
  /// ordinal packed into the name pointer - the documented MAKEINTRESOURCE
  /// trick, which is how every Win32 app does this.
  static void applySystemMenuTheme({bool force = false}) {
    if (_menuThemeApplied && !force) return;

    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      final _LoadLibraryW load = kernel32
          .lookupFunction<_LoadLibraryWNative, _LoadLibraryW>('LoadLibraryW');
      final _GetProcAddress proc = kernel32.lookupFunction<
          _GetProcAddressNative, _GetProcAddress>('GetProcAddress');

      final int module = using<int>((Arena arena) {
        return load('uxtheme.dll'.toNativeUtf16(allocator: arena));
      });
      if (module == 0) return;

      // Ordinal 135: SetPreferredAppMode(int mode)
      final int setMode = proc(module, Pointer<Void>.fromAddress(135));
      if (setMode != 0) {
        final _SetPreferredAppMode apply =
            Pointer<NativeFunction<_SetPreferredAppModeNative>>.fromAddress(
          setMode,
        ).asFunction<_SetPreferredAppMode>();

        final bool dark = systemPrefersDark();
        apply(dark ? _appModeForceDark : _appModeForceLight);
        dlog.write('windowfx', 'menu theme -> ${dark ? 'dark' : 'light'}');
      } else {
        // Windows 10 1809 and older: nothing to do, menus stay native.
        dlog.write('windowfx', 'SetPreferredAppMode unavailable');
      }

      // Ordinal 136: FlushMenuThemes()
      final int flush = proc(module, Pointer<Void>.fromAddress(136));
      if (flush != 0) {
        Pointer<NativeFunction<_FlushMenuThemesNative>>.fromAddress(flush)
            .asFunction<_FlushMenuThemes>()();
      }

      _menuThemeApplied = true;
    } catch (e) {
      dlog.warn('windowfx', 'menu theme failed: $e');
    }
  }

  /// Re-reads the system theme; called before the tray menu pops up so the
  /// menu follows a theme switch without restarting the app.
  static void refreshMenuTheme() {
    final int mode = _appModeDefault; // keeps the constant referenced
    assert(mode == 0);
    applySystemMenuTheme(force: true);
  }
}

// ---------------------------------------------------------------------------
// FFI signatures
// ---------------------------------------------------------------------------

typedef _FindWindowWNative = IntPtr Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);
typedef _FindWindowW = int Function(
  Pointer<Utf16> lpClassName,
  Pointer<Utf16> lpWindowName,
);

typedef _DwmSetWindowAttributeNative = Int32 Function(
  IntPtr hwnd,
  Uint32 attribute,
  Pointer<Void> value,
  Uint32 size,
);
typedef _DwmSetWindowAttribute = int Function(
  int hwnd,
  int attribute,
  Pointer<Void> value,
  int size,
);

typedef _RegGetValueWNative = Int32 Function(
  IntPtr hkey,
  Pointer<Utf16> subKey,
  Pointer<Utf16> value,
  Uint32 flags,
  Pointer<Uint32> type,
  Pointer<Void> data,
  Pointer<Uint32> dataSize,
);
typedef _RegGetValueW = int Function(
  int hkey,
  Pointer<Utf16> subKey,
  Pointer<Utf16> value,
  int flags,
  Pointer<Uint32> type,
  Pointer<Void> data,
  Pointer<Uint32> dataSize,
);

typedef _LoadLibraryWNative = IntPtr Function(Pointer<Utf16> name);
typedef _LoadLibraryW = int Function(Pointer<Utf16> name);

typedef _GetProcAddressNative = IntPtr Function(
  IntPtr module,
  Pointer<Void> name,
);
typedef _GetProcAddress = int Function(int module, Pointer<Void> name);

typedef _SetPreferredAppModeNative = Int32 Function(Int32 mode);
typedef _SetPreferredAppMode = int Function(int mode);

typedef _FlushMenuThemesNative = Void Function();
typedef _FlushMenuThemes = void Function();
