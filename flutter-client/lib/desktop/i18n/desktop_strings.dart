import 'dart:io';

import '../logic/connection_phase.dart';

/// Desktop UI copy in Russian and English.
///
/// Kept as a tiny hand-written table rather than pulling in intl/ARB: the
/// desktop surface is small, this adds no build step, and it can be swapped
/// for the shared localisation layer later without touching call sites.
class DesktopStrings {
  const DesktopStrings._(this.languageCode, this._map);

  final String languageCode;
  final Map<String, String> _map;

  bool get isRussian => languageCode == 'ru';

  String _t(String key) => _map[key] ?? _en[key] ?? key;

  /// Resolves 'system' against the OS locale.
  static DesktopStrings resolve(String preference) {
    if (preference == 'ru') return russian;
    if (preference == 'en') return english;

    final locale = Platform.localeName.toLowerCase();
    // Russian is the default for the CIS locales this product ships to.
    const russianish = <String>['ru', 'kk', 'be', 'uk', 'ky', 'uz'];
    final prefix = locale.split(RegExp(r'[_\-.]')).first;
    return russianish.contains(prefix) ? russian : english;
  }

  static const DesktopStrings english = DesktopStrings._('en', _en);
  static const DesktopStrings russian = DesktopStrings._('ru', _ru);

  // ---- navigation ----
  String get navHome => _t('navHome');
  String get navServers => _t('navServers');
  String get navStats => _t('navStats');
  String get navSettings => _t('navSettings');

  // ---- connect ----
  String get connect => _t('connect');
  String get disconnect => _t('disconnect');
  String get cancel => _t('cancel');
  String get retry => _t('retry');
  String get dash => '—';

  // ---- metrics ----
  String get publicIp => _t('publicIp');
  String get vpnIp => _t('vpnIp');
  String get duration => _t('duration');
  String get ping => _t('ping');
  String get traffic => _t('traffic');
  String get downloaded => _t('downloaded');
  String get uploaded => _t('uploaded');
  String get tunnel => _t('tunnel');
  String get viaApi => _t('viaApi');

  // ---- servers ----
  String get servers => _t('servers');
  String get autoBestServer => _t('autoBestServer');
  String get autoDescription => _t('autoDescription');
  String get manualLocked => _t('manualLocked');
  String get offline => _t('offline');
  String get load => _t('load');
  String get refresh => _t('refresh');
  String get noServers => _t('noServers');

  // ---- settings: general ----
  String get settings => _t('settings');
  String get sectionGeneral => _t('sectionGeneral');
  String get startWithWindows => _t('startWithWindows');
  String get startMinimized => _t('startMinimized');
  String get language => _t('language');
  String get languageSystem => _t('languageSystem');
  String get animations => _t('animations');
  String get reduceMotion => _t('reduceMotion');

  // ---- settings: vpn ----
  String get sectionVpn => _t('sectionVpn');
  String get autoConnect => _t('autoConnect');
  String get killSwitch => _t('killSwitch');
  String get killSwitchHint => _t('killSwitchHint');
  String get dns => _t('dns');
  String get dnsHint => _t('dnsHint');
  String get mtu => _t('mtu');
  String get keepTunnelWithoutUi => _t('keepTunnelWithoutUi');
  String get keepTunnelHint => _t('keepTunnelHint');
  String get disconnectOnExit => _t('disconnectOnExit');

  // ---- settings: split ----
  String get sectionSplit => _t('sectionSplit');
  String get splitAll => _t('splitAll');
  String get splitOnly => _t('splitOnly');
  String get splitExclude => _t('splitExclude');
  String get splitPickApps => _t('splitPickApps');
  String get splitReconnectNeeded => _t('splitReconnectNeeded');
  String get splitLimited => _t('splitLimited');
  String get running => _t('running');

  // ---- settings: account ----
  String get sectionAccount => _t('sectionAccount');
  String get subscription => _t('subscription');
  String get devices => _t('devices');
  String get logout => _t('logout');
  String get plan => _t('plan');
  String get expires => _t('expires');
  String get free => _t('free');

  // ---- stats ----
  String get statistics => _t('statistics');
  String get today => _t('today');
  String get thisMonth => _t('thisMonth');
  String get allTime => _t('allTime');
  String get vpnTime => _t('vpnTime');
  String get lastDays => _t('lastDays');
  String get noStats => _t('noStats');

  // ---- login ----
  String get signIn => _t('signIn');
  String get identifier => _t('identifier');
  String get password => _t('password');
  String get signingIn => _t('signingIn');
  String get loginHint => _t('loginHint');

  // ---- tray ----
  String get trayConnect => _t('trayConnect');
  String get trayDisconnect => _t('trayDisconnect');
  String get trayServer => _t('trayServer');
  String get trayAutoServer => _t('trayAutoServer');
  String get trayPing => _t('trayPing');
  String get trayTraffic => _t('trayTraffic');
  String get trayOpen => _t('trayOpen');
  String get traySettings => _t('traySettings');
  String get trayExit => _t('trayExit');

  // ---- service ----
  String get serviceMissing => _t('serviceMissing');
  String get serviceMissingHint => _t('serviceMissingHint');

  /// Human label for a connection phase.
  String phaseLabel(ConnectionPhase phase) => _t(phase.labelKey);

  static const Map<String, String> _en = <String, String>{
    'navHome': 'Home',
    'navServers': 'Servers',
    'navStats': 'Statistics',
    'navSettings': 'Settings',
    'connect': 'Connect',
    'disconnect': 'Disconnect',
    'cancel': 'Cancel',
    'retry': 'Try again',
    'publicIp': 'Public IP',
    'vpnIp': 'VPN IP',
    'duration': 'Duration',
    'ping': 'Ping',
    'traffic': 'Traffic',
    'downloaded': 'Downloaded',
    'uploaded': 'Uploaded',
    'tunnel': 'tunnel',
    'viaApi': 'via API',
    'servers': 'Servers',
    'autoBestServer': 'Auto · Best server',
    'autoDescription': 'Picks the fastest available server for you',
    'manualLocked': 'Manual selection is available on a paid plan',
    'offline': 'Offline',
    'load': 'Load',
    'refresh': 'Refresh',
    'noServers': 'No servers available right now',
    'settings': 'Settings',
    'sectionGeneral': 'General',
    'startWithWindows': 'Start with Windows',
    'startMinimized': 'Start minimized to tray',
    'language': 'Language',
    'languageSystem': 'System',
    'animations': 'Animations',
    'reduceMotion': 'Reduce motion',
    'sectionVpn': 'VPN',
    'autoConnect': 'Connect on launch',
    'killSwitch': 'Kill switch',
    'killSwitchHint': 'Blocks all traffic if the tunnel drops',
    'dns': 'DNS',
    'dnsHint': 'Leave empty to use the server-provided DNS',
    'mtu': 'MTU',
    'keepTunnelWithoutUi': 'Keep VPN running when the window is closed',
    'keepTunnelHint': 'Closing the window hides GlukVPN to the tray',
    'disconnectOnExit': 'Disconnect when exiting from tray',
    'sectionSplit': 'Split tunneling',
    'splitAll': 'All apps through VPN',
    'splitOnly': 'Only selected apps',
    'splitExclude': 'All except selected apps',
    'splitPickApps': 'Choose applications',
    'splitReconnectNeeded': 'Reconnect to apply this change',
    'splitLimited': 'Per-app routing is limited in this build',
    'running': 'running',
    'sectionAccount': 'Account',
    'subscription': 'Subscription',
    'devices': 'Devices',
    'logout': 'Sign out',
    'plan': 'Plan',
    'expires': 'Expires',
    'free': 'Free',
    'statistics': 'Statistics',
    'today': 'Today',
    'thisMonth': 'This month',
    'allTime': 'All time',
    'vpnTime': 'VPN time',
    'lastDays': 'Last days',
    'noStats': 'No traffic recorded yet',
    'signIn': 'Sign in',
    'identifier': 'Username or email',
    'password': 'Password',
    'signingIn': 'Signing in…',
    'loginHint': 'Use the same account as on your phone',
    'trayConnect': 'Connect',
    'trayDisconnect': 'Disconnect',
    'trayServer': 'Server',
    'trayAutoServer': 'Auto',
    'trayPing': 'Ping',
    'trayTraffic': 'Traffic',
    'trayOpen': 'Open GlukVPN',
    'traySettings': 'Settings',
    'trayExit': 'Exit',
    'serviceMissing': 'Tunnel service unavailable',
    'serviceMissingHint':
        'GlukVPN cannot reach its Windows tunnel service. Reinstall the app '
            'or allow the elevation prompt.',
    // phases
    'phase.disconnected': 'Disconnected',
    'phase.connecting': 'Connecting…',
    'phase.connected': 'Connected',
    'phase.disconnecting': 'Disconnecting…',
    'phase.serverUnavailable': 'Server unavailable',
    'phase.connectionFailed': 'Connection failed',
    'phase.sessionExpired': 'Session expired',
    'phase.limitReached': 'Limit reached',
    'phase.accessRevoked': 'Access revoked',
    'phase.tunnelLost': 'Tunnel lost',
  };

  static const Map<String, String> _ru = <String, String>{
    'navHome': 'Главная',
    'navServers': 'Серверы',
    'navStats': 'Статистика',
    'navSettings': 'Настройки',
    'connect': 'Подключиться',
    'disconnect': 'Отключиться',
    'cancel': 'Отмена',
    'retry': 'Повторить',
    'publicIp': 'ВНЕШНИЙ IP',
    'vpnIp': 'VPN IP',
    'duration': 'ДЛИТЕЛЬНОСТЬ',
    'ping': 'ПИНГ',
    'traffic': 'ТРАФИК',
    'downloaded': 'Загружено',
    'uploaded': 'Отправлено',
    'tunnel': 'туннель',
    'viaApi': 'через API',
    'servers': 'Серверы',
    'autoBestServer': 'Авто · Лучший сервер',
    'autoDescription': 'Сами подберём самый быстрый доступный сервер',
    'manualLocked': 'Ручной выбор доступен на платном тарифе',
    'offline': 'Недоступен',
    'load': 'Нагрузка',
    'refresh': 'Обновить',
    'noServers': 'Сейчас нет доступных серверов',
    'settings': 'Настройки',
    'sectionGeneral': 'Общие',
    'startWithWindows': 'Запуск вместе с Windows',
    'startMinimized': 'Запускаться свёрнутым в трей',
    'language': 'Язык',
    'languageSystem': 'Системный',
    'animations': 'Анимации',
    'reduceMotion': 'Меньше движения',
    'sectionVpn': 'VPN',
    'autoConnect': 'Подключаться при запуске',
    'killSwitch': 'Kill switch',
    'killSwitchHint': 'Блокирует весь трафик, если туннель упал',
    'dns': 'DNS',
    'dnsHint': 'Оставьте пустым, чтобы использовать DNS сервера',
    'mtu': 'MTU',
    'keepTunnelWithoutUi': 'Держать VPN при закрытом окне',
    'keepTunnelHint': 'Закрытие окна прячет GlukVPN в трей',
    'disconnectOnExit': 'Отключать VPN при выходе из трея',
    'sectionSplit': 'Туннелирование',
    'splitAll': 'Весь трафик через VPN',
    'splitOnly': 'Только выбранные приложения',
    'splitExclude': 'Всё, кроме выбранных приложений',
    'splitPickApps': 'Выбрать приложения',
    'splitReconnectNeeded': 'Переподключитесь, чтобы применить изменение',
    'splitLimited': 'В этой сборке поапповый роутинг ограничен',
    'running': 'запущено',
    'sectionAccount': 'Аккаунт',
    'subscription': 'Подписка',
    'devices': 'Устройства',
    'logout': 'Выйти',
    'plan': 'Тариф',
    'expires': 'Действует до',
    'free': 'Бесплатный',
    'statistics': 'Статистика',
    'today': 'Сегодня',
    'thisMonth': 'За месяц',
    'allTime': 'За всё время',
    'vpnTime': 'Время VPN',
    'lastDays': 'Последние дни',
    'noStats': 'Трафик пока не записан',
    'signIn': 'Войти',
    'identifier': 'Логин или email',
    'password': 'Пароль',
    'signingIn': 'Входим…',
    'loginHint': 'Тот же аккаунт, что и на телефоне',
    'trayConnect': 'Подключиться',
    'trayDisconnect': 'Отключиться',
    'trayServer': 'Сервер',
    'trayAutoServer': 'Авто',
    'trayPing': 'Пинг',
    'trayTraffic': 'Трафик',
    'trayOpen': 'Открыть GlukVPN',
    'traySettings': 'Настройки',
    'trayExit': 'Выход',
    'serviceMissing': 'Служба туннеля недоступна',
    'serviceMissingHint':
        'GlukVPN не видит свою службу туннеля. Переустановите приложение '
            'или разрешите запрос прав администратора.',
    // phases
    'phase.disconnected': 'Не подключено',
    'phase.connecting': 'Подключение…',
    'phase.connected': 'Подключено',
    'phase.disconnecting': 'Отключение…',
    'phase.serverUnavailable': 'Сервер недоступен',
    'phase.connectionFailed': 'Не удалось подключиться',
    'phase.sessionExpired': 'Сессия истекла',
    'phase.limitReached': 'Достигнут лимит',
    'phase.accessRevoked': 'Доступ отозван',
    'phase.tunnelLost': 'Туннель потерян',
  };
}
