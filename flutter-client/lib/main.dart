import 'package:flutter/material.dart';

import 'app.dart';
import 'services/api_client.dart';
import 'services/ping_service.dart';
import 'services/secure_store.dart';
import 'services/vpn_service.dart';
import 'state/auth_controller.dart';
import 'state/vpn_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Wired up once here so the whole app shares a single HTTP client, a single
  // secure store and a single tunnel handle.
  final ApiClient api = ApiClient();
  final SecureStore store = SecureStore();
  final AuthController auth = AuthController(api: api, store: store);
  final VpnController vpn = VpnController(
    api: api,
    vpn: VpnService(),
    ping: PingService(),
    auth: auth,
  );

  runApp(GlukVpnApp(auth: auth, vpn: vpn));
}
