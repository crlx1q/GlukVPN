import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'config.dart';
import 'i18n/app_strings.dart';
import 'services/api_client.dart';
import 'services/connectivity_service.dart';
import 'services/ping_service.dart';
import 'services/secure_store.dart';
import 'services/telemetry_service.dart';
import 'services/update_checker.dart';
import 'services/vpn_service.dart';
import 'state/auth_controller.dart';
import 'state/channel_controller.dart';
import 'state/vpn_controller.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(GlukTheme.systemOverlay);

  // Uncaught errors now leave the phone instead of only reaching a console
  // nobody is attached to. Both hooks are installed before anything else is
  // wired up, so a failure during startup is reported too, and the local
  // output is unchanged - presentError still runs, the report is an addition.
  final TelemetryService telemetry = TelemetryService();
  TelemetryService.instance = telemetry;
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    telemetry.report(
      details.exception,
      details.stack,
      context: details.library ?? 'flutter',
    );
  };
  // Everything the framework itself does not catch: async gaps, platform
  // channel replies, throws from timers.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    telemetry.report(error, stack, context: 'android:platformDispatcher');
    return true;
  };

  // Wired up once here so the whole app shares a single HTTP client, a single
  // secure store, a single tunnel handle and one battery/motion listener.
  final ApiClient api = ApiClient();
  final SecureStore store = SecureStore();
  final ConnectivityService connectivity = ConnectivityService(api: api);
  final AuthController auth = AuthController(
    api: api,
    store: store,
    connectivity: connectivity,
  );
  // The network came back: finish restoring the session instead of asking for
  // a password again.
  connectivity.onBackOnline = auth.resumeSession;
  final VpnController vpn = VpnController(
    api: api,
    vpn: VpnService(),
    ping: PingService(),
    auth: auth,
  );
  final MotionController motion = MotionController();

  // ROUND 10 (4.3): the phone reads the release manifest too now. The service
  // has existed since round 4 but was only ever wired up on desktop, so an
  // out-of-date APK had no way of saying so. The manifest is a static file, on
  // purpose: a client is most likely to be stale exactly while the control
  // server is being redeployed.
  final UpdateChecker updates = UpdateChecker();

  // ROUND 11: interface language. Not channel-scoped and not tied to a
  // session - it belongs to the person holding the phone.
  final LocaleController locale = LocaleController(store: store);

  // The Android notification that carries the Disconnect button is written in
  // the interface language, so the VPN controller has to follow the switch.
  void applyLanguage() => vpn.russian = locale.strings.isRussian;
  locale.addListener(applyLanguage);

  final ChannelController channel = ChannelController(
    api: api,
    store: store,
    // Switching channel means a different control plane, a different database
    // and therefore a different session: the auth state is rebuilt from the
    // target channel's own stored refresh token, and VpnController
    // re-initialises itself through AuthGate once that session settles.
    onChannelChanged: (AppChannel next) => auth.bootstrap(),
  );

  // Must happen before the first bootstrap: the channel decides which stored
  // session, device id and WireGuard key pair are even visible.
  await channel.restore();

  // ROUND 12: "the phone stayed on beta and I cannot sign in".
  //
  // The channel is restored from storage before anybody is identified, so a
  // device left on BETA by an earlier build wakes up pointed at a control
  // plane where its account does not exist. Round 11 then hid the switch from
  // non-admins, which removed the only way back from inside the app.
  //
  // Resolve the stored session once, and if it does not belong to an admin or
  // a beta tester - or there is no session at all - return to PROD before the
  // first frame. The extra bootstrap only runs on this rare beta path; the
  // normal one still happens in AuthGate.
  if (channel.isBeta) {
    await auth.bootstrap();
    await channel.demoteIfNotEntitled(auth.user);
  }

  // Before the first frame, so the app never flashes English at somebody who
  // chose Russian last time.
  await locale.restore();
  applyLanguage();

  runApp(
    GlukVpnApp(
      auth: auth,
      vpn: vpn,
      channel: channel,
      motion: motion,
      connectivity: connectivity,
      updates: updates,
      locale: locale,
    ),
  );
}
