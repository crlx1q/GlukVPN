import 'package:flutter/foundation.dart';

import '../services/secure_store.dart';

/// Настройки самого приложения на телефоне — то, что на Windows давно
/// живёт в `DesktopSettings`.
///
/// Почему отдельный контроллер, а не поля в [VpnController]: это
/// предпочтения человека, а не состояние туннеля. Они переживают
/// выход из аккаунта и переключение канала PROD/BETA, поэтому и в
/// хранилище ложатся без привязки к каналу — как язык интерфейса.
///
/// Значения по умолчанию выбраны консервативно: автоподключение
/// выключено (VPN, который включается сам без спроса, — сюрприз, а не
/// удобство), вибрация включена — так приложение вело себя до этого
/// экрана, и обновление не должно менять привычное поведение.
class AppSettings extends ChangeNotifier {
  AppSettings({required SecureStore store}) : _store = store;

  final SecureStore _store;

  bool _autoConnectOnLaunch = false;
  bool _haptics = true;
  bool _restored = false;

  /// Поднимать туннель сразу после запуска приложения.
  ///
  /// Аналог `DesktopSettings.autoConnect`. Не путать с «always-on VPN» в
  /// настройках Android: тот режим держит система и включается он там же.
  bool get autoConnectOnLaunch => _autoConnectOnLaunch;

  /// Короткая отдача на нажатие и на момент, когда туннель реально
  /// заработал.
  bool get haptics => _haptics;

  /// До первого [restore] значения — только умолчания.
  bool get restored => _restored;

  Future<void> restore() async {
    _autoConnectOnLaunch = await _store.readAutoConnectOnLaunch() ?? false;
    _haptics = await _store.readHaptics() ?? true;
    _restored = true;
    notifyListeners();
  }

  Future<void> setAutoConnectOnLaunch(bool value) async {
    if (_autoConnectOnLaunch == value) return;
    _autoConnectOnLaunch = value;
    // Переключатель должен срабатывать мгновенно, а запись в keystore
    // может занять десятки миллисекунд.
    notifyListeners();
    await _store.writeAutoConnectOnLaunch(value);
  }

  Future<void> setHaptics(bool value) async {
    if (_haptics == value) return;
    _haptics = value;
    notifyListeners();
    await _store.writeHaptics(value);
  }
}
