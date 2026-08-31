import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'desktop_log.dart';

/// Guarantees that only one GlukVPN client runs per machine.
///
/// Without this, every double-click of the shortcut started another copy: two
/// tray icons, two heartbeats, two clients fighting over the same named pipe
/// and the same device slot. A VPN client is a singleton by nature.
///
/// The guard is a named kernel mutex, which is the standard Windows answer:
///
///  * it is created before any UI exists, so the second copy never flashes a
///    window,
///  * the kernel releases it automatically if the first copy crashes, so a
///    stale lock file can never lock the user out,
///  * `Global\` scope means it also holds across fast user switching.
///
/// The second copy is not silently killed - it surfaces the window of the copy
/// that is already running and says so, which is what the user actually wants
/// when they click the icon again.
class SingleInstance {
  SingleInstance._();

  static const String _mutexName = r'Global\GlukVPN.Desktop.SingleInstance';

  /// Window class registered by every Flutter Windows runner.
  static const String _windowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';
  static const String _windowTitle = 'GlukVPN';

  static const int _errorAlreadyExists = 183;

  static const int _swShow = 5;
  static const int _swRestore = 9;

  static const int _mbIconInformation = 0x40;
  static const int _mbSetForeground = 0x00010000;
  static const int _mbTopmost = 0x00040000;

  /// Kept for the lifetime of the process on purpose: closing the handle would
  /// release the lock and let a second copy in.
  static int _mutex = 0;

  static bool get isOwner => _mutex != 0;

  /// True when this process is the first instance and may continue booting.
  ///
  /// Any failure inside the guard returns true: a cosmetic protection must
  /// never be able to stop the client from starting.
  static bool claim() {
    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      final _CreateMutexW create = kernel32
          .lookupFunction<_CreateMutexWNative, _CreateMutexW>('CreateMutexW');
      final _GetLastError lastError = kernel32
          .lookupFunction<_GetLastErrorNative, _GetLastError>('GetLastError');

      // GetLastError has to be read immediately after the call, so the name is
      // allocated and freed by hand instead of through an arena.
      final Pointer<Utf16> name = _mutexName.toNativeUtf16();
      final int handle = create(nullptr, 0, name);
      final int error = lastError();
      calloc.free(name);

      if (handle == 0) {
        dlog.warn('single', 'CreateMutexW failed, error $error');
        return true;
      }

      _mutex = handle;

      if (error == _errorAlreadyExists) {
        dlog.write('single', 'another instance is already running');
        return false;
      }

      dlog.write('single', 'instance lock acquired');
      return true;
    } catch (e) {
      dlog.warn('single', 'instance guard unavailable: $e');
      return true;
    }
  }

  /// Raises the window of the copy that is already running, then tells the
  /// user what happened. Called only from the losing process, right before it
  /// exits.
  static void surfaceRunningInstance({required bool russian}) {
    int handle = 0;
    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final _FindWindowW find =
          user32.lookupFunction<_FindWindowWNative, _FindWindowW>('FindWindowW');
      final _ShowWindow show =
          user32.lookupFunction<_ShowWindowNative, _ShowWindow>('ShowWindow');
      final _SetForegroundWindow foreground = user32.lookupFunction<
          _SetForegroundWindowNative, _SetForegroundWindow>(
        'SetForegroundWindow',
      );
      final _IsIconic iconic =
          user32.lookupFunction<_IsIconicNative, _IsIconic>('IsIconic');

      handle = using<int>((Arena arena) {
        // Match on class and title: another Flutter app must never be raised.
        final int byTitle = find(
          _windowClass.toNativeUtf16(allocator: arena),
          _windowTitle.toNativeUtf16(allocator: arena),
        );
        if (byTitle != 0) return byTitle;
        return find(_windowClass.toNativeUtf16(allocator: arena), nullptr);
      });

      if (handle != 0) {
        // The running copy may be hidden in the tray, minimised, or simply
        // behind other windows; all three need a different verb.
        show(handle, iconic(handle) != 0 ? _swRestore : _swShow);
        foreground(handle);
        dlog.write('single', 'raised the window of the running instance');
      } else {
        dlog.write('single', 'running instance has no window to raise');
      }
    } catch (e) {
      dlog.warn('single', 'could not raise the running instance: $e');
    }

    _notify(russian: russian, raised: handle != 0);
  }

  static void _notify({required bool russian, required bool raised}) {
    final String text = russian
        ? (raised
            ? 'GlukVPN уже запущен.\n\nОкно активной копии вынесено на передний план.'
            : 'GlukVPN уже запущен и работает в трее.\n\nНажмите значок GlukVPN рядом с часами, чтобы открыть окно.')
        : (raised
            ? 'GlukVPN is already running.\n\nThe existing window has been brought to the front.'
            : 'GlukVPN is already running in the tray.\n\nClick the GlukVPN icon next to the clock to open the window.');

    try {
      final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
      final _MessageBoxW box =
          user32.lookupFunction<_MessageBoxWNative, _MessageBoxW>('MessageBoxW');

      using((Arena arena) {
        box(
          0,
          text.toNativeUtf16(allocator: arena),
          'GlukVPN'.toNativeUtf16(allocator: arena),
          _mbIconInformation | _mbSetForeground | _mbTopmost,
        );
      });
    } catch (e) {
      dlog.warn('single', 'notice failed: $e');
    }
  }
}

// ---------------------------------------------------------------------------
// FFI signatures
// ---------------------------------------------------------------------------

typedef _CreateMutexWNative = IntPtr Function(
  Pointer<Void> attributes,
  Int32 initialOwner,
  Pointer<Utf16> name,
);
typedef _CreateMutexW = int Function(
  Pointer<Void> attributes,
  int initialOwner,
  Pointer<Utf16> name,
);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastError = int Function();

typedef _FindWindowWNative = IntPtr Function(
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);
typedef _FindWindowW = int Function(
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);

typedef _ShowWindowNative = Int32 Function(IntPtr hwnd, Int32 command);
typedef _ShowWindow = int Function(int hwnd, int command);

typedef _SetForegroundWindowNative = Int32 Function(IntPtr hwnd);
typedef _SetForegroundWindow = int Function(int hwnd);

typedef _IsIconicNative = Int32 Function(IntPtr hwnd);
typedef _IsIconic = int Function(int hwnd);

typedef _MessageBoxWNative = Int32 Function(
  IntPtr hwnd,
  Pointer<Utf16> text,
  Pointer<Utf16> caption,
  Uint32 type,
);
typedef _MessageBoxW = int Function(
  int hwnd,
  Pointer<Utf16> text,
  Pointer<Utf16> caption,
  int type,
);
