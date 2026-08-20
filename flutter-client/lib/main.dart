import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'config.dart';
import 'services/api_client.dart';
import 'services/ping_service.dart';
import 'services/secure_store.dart';
import 'services/vpn_service.dart';
import 'state/auth_controller.dart';
import 'state/channel_controller.dart';
import 'state/vpn_controller.dart';
import 'theme/app_theme.dart';
import 'theme/motion.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(GlukTheme.systemOverlay);

  // Wired up once here so the whole app shares a single HTTP client, a single
  // secure store, a single tunnel handle and one battery/motion listener.
  final ApiClient api = ApiClient();
  final SecureStore store = SecureStore();
  final AuthController auth = AuthController(api: api, store: store);
  final VpnController vpn = VpnController(
    api: api,
    vpn: VpnService(),
    ping: PingService(),
    auth: auth,
  );
  final MotionController motion = MotionController();

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

  runApp(
    GlukVpnApp(auth: auth, vpn: vpn, channel: channel, motion: motion),
  );
}
