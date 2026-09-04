import '../state/desktop_settings.dart';
import 'connection_phase.dart';

/// Command-line flag the autostart Run entry passes so the app comes up in the
/// tray. Also honoured on a manual launch, so a shortcut can carry it.
const String kStartHiddenFlag = '--hidden';

/// What the app does in its first seconds, decided in one place.
///
/// ROUND 26. The three Quick-start switches are independent of each other:
///
///  * **Start with Windows** only decides whether a Run entry exists (and it
///    passes [kStartHiddenFlag] when Start minimised is on);
///  * **Start minimised** hides the window on *every* launch, manual or not -
///    the flag is merely a second way of asking for the same thing;
///  * **Connect on launch** connects as soon as the account is known to be
///    signed in and the service has been probed, whether or not the window is
///    on screen.
///
/// The decision used to be spread over `main_windows.dart` and the controller,
/// which is how "started hidden but never connected" and "connected on every
/// sign-in" both crept in. Pure, so it is unit-tested on any machine.
class StartupPlan {
  const StartupPlan({
    required this.startHidden,
    required this.autoConnect,
    required this.reason,
  });

  /// Do not show the main window; the tray icon is the only surface.
  final bool startHidden;

  /// Call `connect()` without any user action.
  final bool autoConnect;

  /// Why [autoConnect] came out the way it did - for the boot log.
  final String reason;

  @override
  String toString() =>
      'StartupPlan(hidden=$startHidden, autoConnect=$autoConnect, $reason)';
}

/// Whether the main window stays hidden on this launch.
///
/// Independent of `startWithWindows`: a user who launches GlukVPN by hand and
/// asked for "start minimised" gets exactly that.
bool startsHidden({
  required DesktopSettings settings,
  required List<String> args,
}) =>
    args.contains(kStartHiddenFlag) || settings.startMinimized;

/// Decides the startup behaviour for the current state of the app.
///
/// [autoConnectAttempted] is true once this process has already connected on
/// its own: "connect on launch" means once per launch, not on every sign-in
/// and not again after the user pressed Disconnect.
StartupPlan startupPlan({
  required DesktopSettings settings,
  required List<String> args,
  required bool authenticated,
  ConnectionPhase phase = ConnectionPhase.disconnected,
  bool autoConnectAttempted = false,
}) {
  final bool hidden = startsHidden(settings: settings, args: args);

  String reason;
  bool connect = false;
  if (!settings.autoConnect) {
    reason = 'auto-connect off';
  } else if (autoConnectAttempted) {
    reason = 'auto-connect already attempted this launch';
  } else if (!authenticated) {
    reason = 'not signed in yet';
  } else if (phase != ConnectionPhase.disconnected) {
    // A tunnel adopted from the service, a connect already in flight, or an
    // error the user has to read first. None of them wants a second connect.
    reason = 'phase is ${phase.name}';
  } else {
    connect = true;
    reason = 'auto-connect on, signed in, no tunnel';
  }

  return StartupPlan(startHidden: hidden, autoConnect: connect, reason: reason);
}
