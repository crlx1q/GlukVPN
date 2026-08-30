import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'app_paths.dart';

/// Current state of the privileged tunnel service.
enum ServiceInstallState {
  /// Installed and running — the happy path.
  running,

  /// Installed but stopped; we can start it (needs elevation once).
  installedStopped,

  /// Not registered with the SCM at all.
  notInstalled,

  /// GlukVpnTunnelService.exe is missing from the install directory.
  binaryMissing,
}

/// Installs and starts GlukVpnTunnelService when needed.
///
/// Requirement 2: the user must never touch PowerShell or a terminal. The
/// installer normally registers the service, so this path only fires for
/// portable copies or if someone removed the service manually. It costs at
/// most one UAC prompt, ever.
class ServiceBootstrap {
  ServiceBootstrap({AppPaths? paths, this.serviceName = 'GlukVpnTunnel'})
      : _paths = paths ?? AppPaths();

  final AppPaths _paths;
  final String serviceName;

  /// Ensures the service exists and is running. Returns the final state.
  Future<ServiceInstallState> ensureInstalledAndRunning() async {
    var state = queryState();

    if (state == ServiceInstallState.running) return state;

    if (state == ServiceInstallState.binaryMissing) return state;

    if (state == ServiceInstallState.notInstalled) {
      final ok = await _elevate('--install');
      if (!ok) return ServiceInstallState.notInstalled;
      if (await _waitUntilRunning()) return ServiceInstallState.running;
      state = queryState();
    }

    if (state == ServiceInstallState.installedStopped) {
      if (startService()) {
        if (await _waitUntilRunning()) return ServiceInstallState.running;
      }
      // Starting without rights failed; ask for elevation once.
      final ok = await _elevate('--start');
      if (ok && await _waitUntilRunning()) return ServiceInstallState.running;
    }

    return queryState();
  }

  /// Reads the SCM without needing elevation.
  ServiceInstallState queryState() {
    if (!File(_paths.tunnelServiceExePath).existsSync()) {
      return ServiceInstallState.binaryMissing;
    }

    final scm = OpenSCManager(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (scm == NULL) return ServiceInstallState.notInstalled;

    final namePtr = serviceName.toNativeUtf16();
    int service = NULL;
    try {
      service = OpenService(scm, namePtr, SERVICE_QUERY_STATUS);
      if (service == NULL) return ServiceInstallState.notInstalled;

      final status = calloc<SERVICE_STATUS>();
      try {
        if (QueryServiceStatus(service, status) == 0) {
          return ServiceInstallState.installedStopped;
        }
        final current = status.ref.dwCurrentState;
        if (current == SERVICE_RUNNING || current == SERVICE_START_PENDING) {
          return ServiceInstallState.running;
        }
        return ServiceInstallState.installedStopped;
      } finally {
        calloc.free(status);
      }
    } finally {
      if (service != NULL) CloseServiceHandle(service);
      CloseServiceHandle(scm);
      calloc.free(namePtr);
    }
  }

  /// Attempts a plain (non-elevated) start. Works when the current user has
  /// been granted SERVICE_START, which the installer does not require.
  bool startService() {
    final scm = OpenSCManager(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (scm == NULL) return false;

    final namePtr = serviceName.toNativeUtf16();
    int service = NULL;
    try {
      service = OpenService(scm, namePtr, SERVICE_START);
      if (service == NULL) return false;
      return StartService(service, 0, nullptr) != 0;
    } finally {
      if (service != NULL) CloseServiceHandle(service);
      CloseServiceHandle(scm);
      calloc.free(namePtr);
    }
  }

  /// Relaunches the service binary elevated with [verbArg].
  ///
  /// Uses ShellExecute with the "runas" verb, which is the documented way to
  /// request elevation for a child process.
  Future<bool> _elevate(String verbArg) async {
    final exe = _paths.tunnelServiceExePath;
    if (!File(exe).existsSync()) return false;

    final verb = 'runas'.toNativeUtf16();
    final file = exe.toNativeUtf16();
    final args = verbArg.toNativeUtf16();
    final dir = File(exe).parent.path.toNativeUtf16();

    try {
      final rc = ShellExecute(NULL, verb, file, args, dir, SW_HIDE);
      // ShellExecute returns > 32 on success. Anything else (notably
      // SE_ERR_ACCESSDENIED = 5, i.e. the user clicked No on the UAC prompt)
      // is a failure we surface honestly instead of retrying in a loop.
      return rc > 32;
    } finally {
      calloc.free(verb);
      calloc.free(file);
      calloc.free(args);
      calloc.free(dir);
    }
  }

  Future<bool> _waitUntilRunning({
    Duration timeout = const Duration(seconds: 12),
    Duration interval = const Duration(milliseconds: 350),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (queryState() == ServiceInstallState.running) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  /// User-facing explanation for a non-running state.
  static String describe(ServiceInstallState state) {
    switch (state) {
      case ServiceInstallState.running:
        return 'Tunnel service is running.';
      case ServiceInstallState.installedStopped:
        return 'Tunnel service is installed but stopped.';
      case ServiceInstallState.notInstalled:
        return 'Tunnel service is not installed. Reinstall GlukVPN or allow '
            'the elevation prompt.';
      case ServiceInstallState.binaryMissing:
        return 'GlukVpnTunnelService.exe is missing from the installation '
            'folder.';
    }
  }
}
