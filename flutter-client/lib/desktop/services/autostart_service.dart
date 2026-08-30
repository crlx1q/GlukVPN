import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Manages the "Start with Windows" preference.
///
/// Writes HKCU\Software\Microsoft\Windows\CurrentVersion\Run, which is the
/// per-user Run key. Deliberately not HKLM: that would need admin rights on
/// every toggle, and the tunnel service already covers the machine-wide part
/// of startup. The UI process starting itself is purely a user preference.
///
/// The installer writes exactly the same value, so the two never fight.
class AutostartService {
  const AutostartService({
    this.valueName = 'GlukVPN',
    this.hiddenFlag = '--hidden',
  });

  static const String _runKeyPath =
      r'Software\Microsoft\Windows\CurrentVersion\Run';

  final String valueName;

  /// Argument appended when the app should come up straight into the tray.
  final String hiddenFlag;

  String get _exePath => Platform.resolvedExecutable;

  String _command({required bool minimized}) {
    final quoted = '"$_exePath"';
    return minimized ? '$quoted $hiddenFlag' : quoted;
  }

  /// True when a Run entry for GlukVPN exists.
  bool isEnabled() => read() != null;

  /// Current Run value, or null when absent.
  String? read() {
    final keyPath = _runKeyPath.toNativeUtf16();
    final name = valueName.toNativeUtf16();
    final handle = calloc<HKEY>();

    try {
      final opened = RegOpenKeyEx(HKEY_CURRENT_USER, keyPath, 0, KEY_READ, handle);
      if (opened != ERROR_SUCCESS) return null;

      try {
        const bufferChars = 1024;
        final buffer = calloc<Uint16>(bufferChars).cast<Utf16>();
        final size = calloc<Uint32>()..value = bufferChars * 2;
        final type = calloc<Uint32>();

        try {
          final rc = RegQueryValueEx(
            handle.value,
            name,
            nullptr,
            type,
            buffer.cast<Uint8>(),
            size,
          );
          if (rc != ERROR_SUCCESS) return null;
          return buffer.toDartString();
        } finally {
          calloc.free(buffer);
          calloc.free(size);
          calloc.free(type);
        }
      } finally {
        RegCloseKey(handle.value);
      }
    } finally {
      calloc.free(keyPath);
      calloc.free(name);
      calloc.free(handle);
    }
  }

  /// Creates or refreshes the Run entry.
  ///
  /// Always rewrites the value so that moving or reinstalling the app fixes a
  /// stale path automatically.
  bool enable({bool minimized = false}) {
    final keyPath = _runKeyPath.toNativeUtf16();
    final name = valueName.toNativeUtf16();
    final handle = calloc<HKEY>();
    final command = _command(minimized: minimized);
    final data = command.toNativeUtf16();

    try {
      final opened =
          RegCreateKeyEx(
        HKEY_CURRENT_USER,
        keyPath,
        0,
        nullptr,
        0,
        KEY_SET_VALUE,
        nullptr,
        handle,
        nullptr,
      );
      if (opened != ERROR_SUCCESS) return false;

      try {
        // Byte count must include the terminating null.
        final bytes = (command.length + 1) * 2;
        final rc = RegSetValueEx(
          handle.value,
          name,
          0,
          REG_SZ,
          data.cast<Uint8>(),
          bytes,
        );
        return rc == ERROR_SUCCESS;
      } finally {
        RegCloseKey(handle.value);
      }
    } finally {
      calloc.free(keyPath);
      calloc.free(name);
      calloc.free(handle);
      calloc.free(data);
    }
  }

  /// Removes the Run entry. Succeeds when it was already absent.
  bool disable() {
    final keyPath = _runKeyPath.toNativeUtf16();
    final name = valueName.toNativeUtf16();
    final handle = calloc<HKEY>();

    try {
      final opened =
          RegOpenKeyEx(HKEY_CURRENT_USER, keyPath, 0, KEY_SET_VALUE, handle);
      if (opened != ERROR_SUCCESS) return true;

      try {
        final rc = RegDeleteValue(handle.value, name);
        return rc == ERROR_SUCCESS || rc == ERROR_FILE_NOT_FOUND;
      } finally {
        RegCloseKey(handle.value);
      }
    } finally {
      calloc.free(keyPath);
      calloc.free(name);
      calloc.free(handle);
    }
  }

  /// Reconciles the registry with the current settings in one call.
  bool apply({required bool startWithWindows, required bool startMinimized}) {
    if (!Platform.isWindows) return false;
    return startWithWindows ? enable(minimized: startMinimized) : disable();
  }
}
