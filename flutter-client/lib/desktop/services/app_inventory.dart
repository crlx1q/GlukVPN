import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final CreateToolhelp32Snapshot = _kernel32.lookupFunction<IntPtr Function(Uint32, Uint32), int Function(int, int)>('CreateToolhelp32Snapshot');
final Process32First = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<PROCESSENTRY32>), int Function(int, Pointer<PROCESSENTRY32>)>('Process32FirstW');
final Process32Next = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<PROCESSENTRY32>), int Function(int, Pointer<PROCESSENTRY32>)>('Process32NextW');
const int TH32CS_SNAPPROCESS = 0x00000002;

final class PROCESSENTRY32 extends Struct {
  @Uint32() external int dwSize;
  @Uint32() external int cntUsage;
  @Uint32() external int th32ProcessID;
  @IntPtr() external int th32DefaultHeapID;
  @Uint32() external int th32ModuleID;
  @Uint32() external int cntThreads;
  @Uint32() external int th32ParentProcessID;
  @Int32()  external int pcPriClassBase;
  @Uint32() external int dwFlags;
  @Array(260) external Array<Uint16> _szExeFile;
  
  String get szExeFile {
    final buffer = StringBuffer();
    for (var i = 0; i < 260; i++) {
      final char = _szExeFile[i];
      if (char == 0) break;
      buffer.writeCharCode(char);
    }
    return buffer.toString();
  }
}

/// One selectable application for split tunnelling.
class InstalledApp {
  const InstalledApp({
    required this.displayName,
    required this.exePath,
    this.running = false,
  });

  final String displayName;
  final String exePath;

  /// True when the executable was found among live processes. Running apps
  /// are shown first because those are what people actually want to route.
  final bool running;

  String get fileName {
    final normalized = exePath.replaceAll('/', r'\');
    final index = normalized.lastIndexOf(r'\');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  @override
  bool operator ==(Object other) =>
      other is InstalledApp &&
      other.exePath.toLowerCase() == exePath.toLowerCase();

  @override
  int get hashCode => exePath.toLowerCase().hashCode;
}

/// Discovers applications the user can add to a split-tunnelling list.
///
/// Two sources are merged:
///   1. currently running processes (Toolhelp32) — accurate and immediate;
///   2. a shallow scan of the usual install roots — catches things that are
///      closed right now.
///
/// This is intentionally not an exhaustive registry crawl: the uninstall keys
/// are full of entries with no usable executable path, and the result would
/// be slower and noisier. Anything missed can still be added via a file
/// picker.
class AppInventory {
  const AppInventory();

  static const List<String> _skipList = <String>[
    'svchost.exe',
    'csrss.exe',
    'wininit.exe',
    'services.exe',
    'lsass.exe',
    'smss.exe',
    'winlogon.exe',
    'dwm.exe',
    'fontdrvhost.exe',
    'registry',
    'memory compression',
    'system',
    'system idle process',
    'runtimebroker.exe',
    'searchhost.exe',
    'shellexperiencehost.exe',
    'startmenuexperiencehost.exe',
    'textinputhost.exe',
    'ctfmon.exe',
    'sihost.exe',
    'taskhostw.exe',
    'conhost.exe',
    'audiodg.exe',
    'wudfhost.exe',
    'spoolsv.exe',
  ];

  Future<List<InstalledApp>> list() async {
    if (!Platform.isWindows) return const <InstalledApp>[];

    final byPath = <String, InstalledApp>{};

    for (final app in _runningProcesses()) {
      byPath[app.exePath.toLowerCase()] = app;
    }

    for (final app in await _scanInstallRoots()) {
      final key = app.exePath.toLowerCase();
      // Never downgrade a "running" entry to "not running".
      byPath.putIfAbsent(key, () => app);
    }

    final result = byPath.values.toList()
      ..sort((InstalledApp a, InstalledApp b) {
        if (a.running != b.running) return a.running ? -1 : 1;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });

    return result;
  }

  /// Enumerates live processes and resolves their full image paths.
  List<InstalledApp> _runningProcesses() {
    final apps = <InstalledApp>[];

    final snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return apps;

    final entry = calloc<PROCESSENTRY32>()
      ..ref.dwSize = sizeOf<PROCESSENTRY32>();

    try {
      if (Process32First(snapshot, entry) == 0) return apps;

      do {
        final name = entry.ref.szExeFile;
        if (name.isEmpty) continue;
        if (_skipList.contains(name.toLowerCase())) continue;

        final path = _imagePathFor(entry.ref.th32ProcessID);
        if (path == null || path.isEmpty) continue;

        apps.add(InstalledApp(
          displayName: _prettyName(name),
          exePath: path,
          running: true,
        ));
      } while (Process32Next(snapshot, entry) != 0);
    } finally {
      calloc.free(entry);
      CloseHandle(snapshot);
    }

    return apps;
  }

  String? _imagePathFor(int pid) {
    // PROCESS_QUERY_LIMITED_INFORMATION works for other users' processes
    // without elevation, which PROCESS_QUERY_INFORMATION does not.
    final handle =
        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (handle == NULL) return null;

    const capacity = MAX_PATH * 2;
    final buffer = wsalloc(capacity);
    final size = calloc<Uint32>()..value = capacity;

    try {
      final ok = QueryFullProcessImageName(handle, 0, buffer, size);
      if (ok == 0) return null;
      return buffer.toDartString();
    } finally {
      free(buffer);
      calloc.free(size);
      CloseHandle(handle);
    }
  }

  Future<List<InstalledApp>> _scanInstallRoots() async {
    final roots = <String>[
      Platform.environment['PROGRAMFILES'] ?? '',
      Platform.environment['PROGRAMFILES(X86)'] ?? '',
      _join(Platform.environment['LOCALAPPDATA'] ?? '', 'Programs'),
    ].where((String p) => p.isNotEmpty).toList();

    final found = <InstalledApp>[];

    for (final root in roots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      await _scanDir(dir, 0, found);
    }

    return found;
  }

  /// Depth-limited scan. Depth 2 covers "Program Files\Vendor\App\app.exe"
  /// which is where virtually everything lives, without walking the whole
  /// tree (which on a real machine takes many seconds).
  Future<void> _scanDir(
    Directory dir,
    int depth,
    List<InstalledApp> sink,
  ) async {
    if (depth > 2) return;
    if (sink.length > 600) return;

    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return; // permission denied on some system folders; skip quietly
    }

    for (final entity in entries) {
      if (entity is File) {
        if (!entity.path.toLowerCase().endsWith('.exe')) continue;
        final name = entity.uri.pathSegments.last;
        if (_skipList.contains(name.toLowerCase())) continue;
        if (_looksLikeHelper(name)) continue;
        sink.add(InstalledApp(
          displayName: _prettyName(name),
          exePath: entity.path,
        ));
      } else if (entity is Directory) {
        await _scanDir(entity, depth + 1, sink);
      }
    }
  }

  /// Filters out updaters, crash handlers and similar noise.
  static bool _looksLikeHelper(String fileName) {
    final lower = fileName.toLowerCase();
    const needles = <String>[
      'unins',
      'update',
      'setup',
      'installer',
      'crashpad',
      'crashreport',
      'helper',
      'watchdog',
      'elevate',
      'repair',
      'diagnostic',
    ];
    return needles.any(lower.contains);
  }

  static String _prettyName(String fileName) {
    var base = fileName;
    if (base.toLowerCase().endsWith('.exe')) {
      base = base.substring(0, base.length - 4);
    }
    if (base.isEmpty) return fileName;
    return base[0].toUpperCase() + base.substring(1);
  }

  static String _join(String a, String b) {
    if (a.isEmpty) return '';
    if (a.endsWith(r'\') || a.endsWith('/')) return '$a$b';
    return '$a\\$b';
  }
}
