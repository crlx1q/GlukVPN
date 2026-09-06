/*
 * Russian / English strings.
 *
 * On first run the language is guessed, in this order:
 *   1. the country the control plane reports for this IP (GeoIP)
 *   2. the browser UI language / navigator.languages
 *   3. the IANA time zone
 * and falls back to English. The user can always override it in Settings.
 */

export const LANGUAGES = ['ru', 'en']

/* Countries where Russian is the working language of the internet. */
const RU_COUNTRIES = ['RU', 'KZ', 'BY', 'KG', 'UZ', 'TJ', 'TM', 'AM', 'AZ', 'GE', 'MD', 'UA']
const RU_LOCALES = /^(ru|be|kk|ky|uk|uz|tg|tk|hy|az|ka|mo)\b/i
const RU_TIMEZONES = [
	'Europe/Moscow', 'Europe/Kaliningrad', 'Europe/Samara', 'Europe/Volgograd', 'Europe/Saratov',
	'Europe/Astrakhan', 'Europe/Ulyanovsk', 'Europe/Kirov', 'Europe/Minsk', 'Europe/Kiev',
	'Europe/Kyiv', 'Europe/Chisinau', 'Asia/Almaty', 'Asia/Aqtau', 'Asia/Aqtobe', 'Asia/Atyrau',
	'Asia/Oral', 'Asia/Qostanay', 'Asia/Qyzylorda', 'Asia/Tashkent', 'Asia/Samarkand',
	'Asia/Bishkek', 'Asia/Dushanbe', 'Asia/Ashgabat', 'Asia/Yerevan', 'Asia/Baku', 'Asia/Tbilisi',
	'Asia/Yekaterinburg', 'Asia/Omsk', 'Asia/Novosibirsk', 'Asia/Krasnoyarsk', 'Asia/Irkutsk',
	'Asia/Yakutsk', 'Asia/Vladivostok', 'Asia/Magadan', 'Asia/Kamchatka',
]

export function fromCountry(countryCode) {
	const cc = String(countryCode ?? '').trim().toUpperCase()
	if (!cc) return null
	return RU_COUNTRIES.includes(cc) ? 'ru' : 'en'
}

export function fromLocales(locales) {
	for (const locale of locales ?? []) {
		if (!locale) continue
		if (RU_LOCALES.test(String(locale))) return 'ru'
		if (/^[a-z]{2}/i.test(String(locale))) return 'en'
	}
	return null
}

export function fromTimeZone(zone) {
	if (!zone) return null
	return RU_TIMEZONES.includes(String(zone)) ? 'ru' : null
}

/** settingsLanguage is 'auto' | 'ru' | 'en'. countryCode comes from the API. */
export function resolveLanguage(settingsLanguage, countryCode) {
	if (LANGUAGES.includes(settingsLanguage)) return settingsLanguage

	const byCountry = fromCountry(countryCode)
	if (byCountry) return byCountry

	const locales = []
	try {
		if (typeof chrome !== 'undefined' && chrome.i18n?.getUILanguage) {
			locales.push(chrome.i18n.getUILanguage())
		}
	} catch {}
	try {
		if (typeof navigator !== 'undefined') {
			locales.push(...(navigator.languages ?? []), navigator.language)
		}
	} catch {}
	const byLocale = fromLocales(locales.filter(Boolean))
	if (byLocale) return byLocale

	try {
		const zone = Intl.DateTimeFormat().resolvedOptions().timeZone
		const byZone = fromTimeZone(zone)
		if (byZone) return byZone
	} catch {}

	return 'en'
}

const en = {
	'nav.vpn': 'VPN',
	'nav.servers': 'Servers',
	'nav.stats': 'Statistics',
	'nav.settings': 'Settings',
	'stats.day': 'Day',
	'stats.week': 'Week',
	'stats.month': 'Month',

	'status.connected': 'CONNECTED',
	'status.connecting': 'CONNECTING',
	'status.disconnecting': 'DISCONNECTING',
	'status.error': 'ERROR',
	'status.idle': 'NOT CONNECTED',
	'status.signedOut': 'SIGNED OUT',
	'status.offline': 'NO INTERNET',

	'stat.publicIp': 'Public IP',
	'stat.vpnIp': 'VPN IP',
	'stat.duration': 'Duration',
	'stat.ping': 'Ping',
	'stat.msUnit': 'ms',
	'stat.rx': 'Downloaded',
	'stat.tx': 'Uploaded',

	'traffic.title': 'Traffic',
	'traffic.down': 'Downloaded',
	'traffic.up': 'Uploaded',

	'loc.locating': 'Detecting location...',
	'loc.unknown': 'Location unknown',
	'loc.signIn': 'Sign in to continue',

	'node.fastest': 'Fastest server',
	'node.load': 'load {n}%',
	'node.offline': 'offline',
	'node.maintenance': 'maintenance',
	'node.none': 'No server selected',
	'node.change': 'Change',

	'servers.title': 'Servers',
	'servers.refresh': 'Refresh',
	'servers.empty': 'No servers available yet.',
	'servers.failed': 'Could not load the server list.',
	'servers.retry': 'Try again',
	'servers.loading': 'Loading servers...',
	'servers.cached': 'Showing the last known list.',
	'login.show': 'show',
	'login.hide': 'hide',
	'nav.profile': 'Profile',
	'profile.title': 'My profile',
	'profile.account': 'GlukVPN account',
	'profile.plan': 'Plan',
	'profile.expires': 'Valid until',
	'profile.devices': 'Devices',
	'profile.status': 'Status',
	'profile.active': 'Active',
	'profile.expired': 'Expired',
	'profile.disabled': 'Disabled',
	'profile.noSub': 'No subscription',
	'profile.free': 'Free',
	'profile.unlimited': 'Unlimited',
	'profile.signOut': 'Sign out',
	'settings.autosaved': 'Saved',
	'dev.active': 'Active',
	'dev.revoked': 'Revoked',
	'dev.thisDevice': 'This browser',
	'dev.online': 'Connected',
	'dev.lastSeen': 'Last seen {when}',
	'dev.never': 'never',
	'dev.limit': '{used} of {max}',
	'dev.page': '{page} of {total}',
	'dev.prevPage': 'Previous page',
	'dev.nextPage': 'Next page',
	'err.limitTitle': 'Device limit reached',
	'login.modeSite': 'Via website',
	'login.modePassword': 'With password',
	'login.siteHint': 'Opens vpn.gluk.tech and signs this browser in.',
	'node.auto': 'Auto',

	'settings.language': 'Language',
	'settings.languageAuto': 'Auto',
	'settings.langAuto': 'Auto',
	'settings.languageHint': 'Auto picks Russian or English from your region.',
	'settings.tunneling': 'Tunnelling',
	'settings.tunnel': 'Tunnelling',
	'settings.tunnelAll': 'All sites',
	'settings.tunnelExcept': 'Except these',
	'settings.tunnelOnly': 'Only these',
	'settings.tunnelAllHint': 'Every site in this browser goes through the VPN.',
	'settings.tunnelExceptHint': 'Everything goes through the VPN except the sites below.',
	'settings.tunnelOnlyHint': 'Only the sites below go through the VPN.',
	'settings.siteList': 'Site list',
	'settings.siteListHint': 'One domain per line. Subdomains are included, * is allowed.',
	'settings.siteListExcept': 'Sites that skip the VPN',
	'settings.siteListOnly': 'Sites that use the VPN',
	'settings.autoConnect': 'Start with the browser',
	'settings.autoConnectHint': 'Connect automatically when the browser starts.',
	'settings.killSwitch': 'Kill switch',
	'settings.killSwitchHint': 'Block traffic instead of leaking if the gateway dies.',
	// Incognito toggle. Chrome keeps the actual permission behind its own
	// per-extension switch, so the row also has to explain where that lives.
	'settings.incognito': 'Tunnel incognito windows',
	'settings.incognitoHint':
		'Off \u2014 the VPN covers regular windows only. On \u2014 Incognito windows are protected too. For that Chrome must allow this extension in Incognito.',
	'settings.incognitoOpenPermission': 'Open chrome://extensions to grant permission',
	'settings.incognitoNotAllowed': 'Chrome has not allowed this extension in Incognito yet',
	'settings.incognitoAllowed': 'Permission granted',
	'settings.devices': 'Devices',
	// ROUND 9: popup.html has asked for these three since round 5 and the table
	// never had them, so t() fell through to its last resort - printing the key.
	// The device filter literally read "devices.filterAll / devices.filterAc...".
	// Any data-i18n attribute without an entry here shows up as raw key.
	'devices.filterAll': 'All',
	'devices.filterActive': 'Active',
	'devices.filterRevoked': 'Revoked',
	'devices.emptyActive': 'No active devices.',
	'devices.emptyRevoked': 'No revoked devices.',
	'settings.devicesFailed': 'Could not load devices.',
	'settings.devicesRetry': 'Retry',
	'settings.devicesEmpty': 'No devices registered.',
	'settings.thisBrowser': 'this browser',
	'settings.revoke': 'Remove',
	'settings.advanced': 'Advanced settings',
	'settings.advancedHint': 'Channel, protocol and direct-connection exceptions.',
	'settings.developer': 'Developer',
	'settings.developerHint': 'Addresses and gateway. Only change these if you know why.',
	'settings.scheme': 'Protocol',
	'settings.schemeHint': 'How the browser talks to the gateway.',
	'settings.channel': 'Channel',
	'settings.apiBase': 'API address',
	'settings.siteBase': 'Website address',
	'settings.gateway': 'Gateway',
	// popup.html has referenced this hint all along; without an entry t() printed
	// the raw key under the gateway fields.
	'settings.gatewayHint': 'Browser gateway host and port. Leave empty to use the selected server.',
	'settings.gatewayHost': 'Host',
	'settings.gatewayPort': 'Port',
	'settings.gatewayScheme': 'Scheme',
	'settings.testGateway': 'Test gateway',
	'settings.bypass': 'Always direct',
	'settings.bypassHint': 'System exceptions that never use the VPN.',
	'settings.save': 'Save',
	'settings.reset': 'Reset',
	'settings.signOut': 'Sign out',
	'settings.saved': 'Saved',
	'settings.saveFailed': 'Could not save settings.',
	'settings.probing': 'Checking...',
	'settings.reachable': 'Reachable, {ms} ms',
	'settings.unreachable': 'Not reachable',
	'settings.enterHost': 'Enter a gateway host first.',
	'settings.saving': 'Saving...',
	'settings.saveFailedShort': 'Not saved',
	'settings.resetDone': 'Reset',
	'settings.autosaveHint': 'Changes are saved automatically.',

	'login.title': 'Sign in to GlukVPN',
	'login.sub': 'Same account as the mobile app.',
	'login.withSite': 'Continue on vpn.gluk.tech',
	'login.or': 'or',
	'login.withPassword': 'Sign in with a password',
	'login.identifier': 'Username or email',
	'login.password': 'Password',
	'login.submit': 'Sign in',
	'login.submitting': 'Signing in...',
	'login.needBoth': 'Enter both fields.',
	'login.failed': 'Sign-in failed.',
	'login.opened': 'Finish signing in on the page that just opened.',
	'login.openFailed': 'Could not open the website.',
	'login.notSignedIn': 'Not signed in yet on the website.',
	'login.waiting': 'Waiting for the website',
	// ROUND 9 (block 4.1): the popup has no registration form of its own -
	// registration needs email delivery, a captcha and the Telegram step, none of
	// which belong in a 380px popup. Both buttons open the one page that already
	// does it properly.
	'login.register': 'Create an account',
	'login.forgot': 'Forgot your password?',
	'login.registerClosed': 'Registration is closed on the beta channel.',

	// ROUND 9 (block 4.2): developer channel. The card itself is the one shared
	// with the desktop and mobile clients: two pills, a version under each, a
	// "using" line and an availability check before the switch happens.
	'dev.title': 'Developer menu',
	'dev.channel': 'Channel',
	'dev.channelHint': 'Separate database and accounts. Switching signs you out.',
	'dev.channelSwitched': 'Channel switched to {channel}. Sign in again.',
	'dev.channelUsing': 'Using: {channel} \u00b7 {version}',
	'dev.channelOff': 'off',
	'dev.channelUnavailableBeta': 'The beta server is currently unavailable',
	'dev.channelUnavailableProd': 'The production server is currently unavailable',
	'dev.channelDisconnectFirst': 'Disconnect the VPN first',
	'dev.version': 'Version {version}',

	// ROUND 9 (block 4.4): update banner.
	'update.title': 'Update available',
	'update.text': 'GlukVPN {version} is out. You are on {current}.',
	'update.action': 'Download',
	'update.later': 'Later',

	'err.tooManyDevices': 'Device limit reached. Remove a device in Settings and try again.',
	'err.no_pending_connect': 'Device slot released. Ready to connect.',
	'err.tooManySessions': 'Another device already holds a tunnel on this account. Disconnect it and try again.',
	'err.keyRegistered': 'This browser\u2019s key was rejected as already registered. A new key is being issued \u2014 try again.',
	'err.network': 'No connection to the control plane.',
	'err.unauthorized': 'Session expired. Please sign in again.',
	'err.forbidden': 'This device is no longer allowed.',
	'err.rateLimited': 'Too many attempts. Wait a moment and try again.',
	'err.noNodes': 'No VPN server is available right now.',
	'err.noGateway': 'Set the gateway host under Advanced before connecting.',
	'err.gatewayUnreachable': 'The gateway is not responding.',
	'err.timeout': 'The request timed out.',
	'err.busy': 'Still working on the last request...',
	'err.unknown': 'Something went wrong.',
	'err.wakeFailed': 'Extension background is not responding. Reopen the popup.',
	'err.title': 'Error',
	'err.connectTitle': 'Connection error',
	'err.connectTimeoutText': 'The server never answered. Check the gateway address in Advanced settings and try again.',
	'err.offlineTitle': 'No internet connection',
	'err.offlineText': 'This computer is offline, so there is nothing to tunnel yet. Connect to a network and try again.',
	// ROUND 9: the remaining raw backend strings. Anything errorKeyFor() cannot
	// classify used to reach the user in English, from the API, mid-sentence.
	'err.badRequest': 'The server rejected the request.',
	'err.notFound': 'Not found.',
	'err.conflict': 'That conflicts with something already on the account.',
	'err.server': 'The server is having trouble. Try again in a minute.',
	'err.maintenance': 'The service is briefly unavailable. Try again shortly.',
	'err.badCredentials': 'Wrong username or password.',
	'err.accountDisabled': 'This account is disabled. Contact support.',
	'err.emailNotVerified': 'Confirm your email address first.',
	'err.noSubscription': 'This account has no active subscription.',
	'err.trafficLimit': 'The monthly traffic allowance is spent. Connecting works again after the allowance resets.',
	'err.captcha': 'The captcha check failed. Try again.',

	'common.none': 'none',
	'common.retry': 'Retry',
	'limit.title': 'Device limit reached',
	'limit.body': 'Release one device slot to register this browser and continue.',
	'limit.release': 'Release',
	'limit.chooseServer': 'Choose server',
	'limit.stillFull': 'The account is still at its device limit.',
	'maintenance.title': 'Scheduled maintenance',
	'maintenance.body': 'The tunnel is paused safely. GlukVPN will retry in about {seconds} seconds.',
	'map.active': '{count} active · {placed} shown',
	'restriction.bittorrent': 'BitTorrent blocked',
	'restriction.smtp25': 'SMTP port 25 blocked',
	'restriction.p2p_ports': 'P2P ports blocked',
	'common.cancel': 'Cancel',
}

const ru = {
	'nav.vpn': 'VPN',
	'nav.servers': 'Серверы',
	'nav.stats': 'Статистика',
	'nav.settings': 'Настройки',
	'stats.day': 'День',
	'stats.week': 'Неделя',
	'stats.month': 'Месяц',

	'status.connected': 'ПОДКЛЮЧЕНО',
	'status.connecting': 'ПОДКЛЮЧЕНИЕ',
	'status.disconnecting': 'ОТКЛЮЧЕНИЕ',
	'status.error': 'ОШИБКА',
	'status.idle': 'НЕ ПОДКЛЮЧЕНО',
	'status.signedOut': 'НЕ ВЫПОЛНЕН ВХОД',
	'status.offline': 'НЕТ ИНТЕРНЕТА',

	'stat.publicIp': 'Внешний IP',
	'stat.vpnIp': 'IP в VPN',
	'stat.duration': 'Время',
	'stat.ping': 'Пинг',
	'stat.msUnit': 'мс',
	'stat.rx': 'Загружено',
	'stat.tx': 'Отправлено',

	'traffic.title': 'Трафик',
	'traffic.down': 'Загружено',
	'traffic.up': 'Отправлено',

	'loc.locating': 'Определяем местоположение...',
	'loc.unknown': 'Местоположение неизвестно',
	'loc.signIn': 'Войдите, чтобы продолжить',

	'node.fastest': 'Самый быстрый сервер',
	'node.load': 'загрузка {n}%',
	'node.offline': 'недоступен',
	'node.maintenance': 'обслуживание',
	'node.none': 'Сервер не выбран',
	'node.change': 'Сменить',

	'servers.title': 'Серверы',
	'servers.refresh': 'Обновить',
	'servers.empty': 'Доступных серверов пока нет.',
	'servers.failed': 'Не удалось загрузить список серверов.',
	'servers.retry': 'Повторить',
	'servers.loading': 'Загружаем серверы...',
	'servers.cached': 'Показан последний известный список.',
	'login.show': 'показать',
	'login.hide': 'скрыть',
	'nav.profile': 'Профиль',
	'profile.title': 'Мой профиль',
	'profile.account': 'Аккаунт GlukVPN',
	'profile.plan': 'Тариф',
	'profile.expires': 'Действует до',
	'profile.devices': 'Устройства',
	'profile.status': 'Статус',
	'profile.active': 'Активна',
	'profile.expired': 'Истекла',
	'profile.disabled': 'Отключена',
	'profile.noSub': 'Нет подписки',
	'profile.free': 'Free',
	'profile.unlimited': 'Бессрочно',
	'profile.signOut': 'Выйти',
	'settings.autosaved': 'Сохранено',
	'dev.active': 'Активно',
	'dev.revoked': 'Отозвано',
	'dev.thisDevice': 'Этот браузер',
	'dev.online': 'Подключено',
	'dev.lastSeen': 'Заходило {when}',
	'dev.never': 'ни разу',
	'dev.limit': '{used} из {max}',
	'dev.page': '{page} из {total}',
	'dev.prevPage': 'Предыдущая страница',
	'dev.nextPage': 'Следующая страница',
	'err.limitTitle': 'Достигнут лимит устройств',
	'login.modeSite': 'Через сайт',
	'login.modePassword': 'По паролю',
	'login.siteHint': 'Откроет vpn.gluk.tech и авторизует этот браузер.',
	'node.auto': 'Авто',

	'settings.language': 'Язык',
	'settings.languageAuto': 'Авто',
	'settings.langAuto': 'Авто',
	'settings.languageHint': 'Авто выбирает русский или английский по вашему региону.',
	'settings.tunneling': 'Туннелирование',
	'settings.tunnel': 'Туннелирование',
	'settings.tunnelAll': 'Все сайты',
	'settings.tunnelExcept': 'Кроме этих',
	'settings.tunnelOnly': 'Только эти',
	'settings.tunnelAllHint': 'Весь трафик браузера идёт через VPN.',
	'settings.tunnelExceptHint': 'Всё идёт через VPN, кроме сайтов из списка.',
	'settings.tunnelOnlyHint': 'Через VPN идут только сайты из списка.',
	'settings.siteList': 'Список сайтов',
	'settings.siteListHint': 'По одному домену в строке. Поддомены учитываются, можно *.',
	'settings.siteListExcept': 'Сайты в обход VPN',
	'settings.siteListOnly': 'Сайты через VPN',
	'settings.autoConnect': 'Запуск вместе с браузером',
	'settings.autoConnectHint': 'Подключаться автоматически при старте браузера.',
	'settings.killSwitch': 'Kill switch',
	'settings.killSwitchHint': 'Блокировать трафик, а не пускать мимо VPN, если шлюз упал.',
	'settings.incognito': 'Туннелировать режим инкогнито',
	'settings.incognitoHint':
		'Выключено \u2014 VPN работает только в обычных вкладках. Включено \u2014 защищает и окна инкогнито. Для этого Chrome должен разрешить расширению работать в инкогнито.',
	'settings.incognitoOpenPermission': 'Открыть chrome://extensions для выдачи разрешения',
	'settings.incognitoNotAllowed': 'Chrome пока не разрешил расширению работать в инкогнито',
	'settings.incognitoAllowed': 'Разрешение выдано',
	'settings.devices': 'Устройства',
	'devices.filterAll': 'Все',
	'devices.filterActive': 'Активные',
	'devices.filterRevoked': 'Отозванные',
	'devices.emptyActive': 'Активных устройств нет.',
	'devices.emptyRevoked': 'Отозванных устройств нет.',
	'settings.devicesFailed': 'Не удалось загрузить устройства.',
	'settings.devicesRetry': 'Повторить',
	'settings.devicesEmpty': 'Устройств пока нет.',
	'settings.thisBrowser': 'этот браузер',
	'settings.revoke': 'Удалить',
	'settings.advanced': 'Расширенные настройки',
	'settings.advancedHint': 'Канал, протокол и исключения для прямого подключения.',
	'settings.developer': 'Для разработчика',
	'settings.developerHint': 'Адреса и шлюз. Меняйте только если понимаете зачем.',
	'settings.scheme': 'Протокол',
	'settings.schemeHint': 'Как браузер общается со шлюзом.',
	'settings.channel': 'Канал',
	'settings.apiBase': 'Адрес API',
	'settings.siteBase': 'Адрес сайта',
	'settings.gateway': 'Шлюз',
	'settings.gatewayHint': 'Хост и порт шлюза браузера. Оставьте пустым, чтобы использовать сервер из списка.',
	'settings.gatewayHost': 'Хост',
	'settings.gatewayPort': 'Порт',
	'settings.gatewayScheme': 'Схема',
	'settings.testGateway': 'Проверить шлюз',
	'settings.bypass': 'Всегда напрямую',
	'settings.bypassHint': 'Системные исключения, которые никогда не идут через VPN.',
	'settings.save': 'Сохранить',
	'settings.reset': 'Сбросить',
	'settings.signOut': 'Выйти',
	'settings.saved': 'Сохранено',
	'settings.saveFailed': 'Не удалось сохранить настройки.',
	'settings.probing': 'Проверяем...',
	'settings.reachable': 'Доступен, {ms} мс',
	'settings.unreachable': 'Недоступен',
	'settings.enterHost': 'Сначала укажите хост шлюза.',
	'settings.saving': 'Сохраняем...',
	'settings.saveFailedShort': 'Не сохранено',
	'settings.resetDone': 'Сброшено',
	'settings.autosaveHint': 'Изменения сохраняются автоматически.',

	'login.title': 'Вход в GlukVPN',
	'login.sub': 'Тот же аккаунт, что и в мобильном приложении.',
	'login.withSite': 'Продолжить на vpn.gluk.tech',
	'login.or': 'или',
	'login.withPassword': 'Войти по паролю',
	'login.identifier': 'Логин или email',
	'login.password': 'Пароль',
	'login.submit': 'Войти',
	'login.submitting': 'Входим...',
	'login.needBoth': 'Заполните оба поля.',
	'login.failed': 'Не удалось войти.',
	'login.opened': 'Завершите вход на открывшейся странице.',
	'login.openFailed': 'Не удалось открыть сайт.',
	'login.notSignedIn': 'На сайте вход ещё не выполнен.',
	'login.waiting': 'Ждём подтверждения с сайта',
	'login.register': 'Создать аккаунт',
	'login.forgot': 'Забыли пароль?',
	'login.registerClosed': 'На бета-канале регистрация закрыта.',

	'dev.title': 'Меню разработчика',
	'dev.channel': 'Канал',
	'dev.channelHint': 'Отдельная база и аккаунты. При переключении вы выйдете из аккаунта.',
	'dev.channelSwitched': 'Канал переключён на {channel}. Войдите заново.',
	'dev.channelUsing': 'Сейчас: {channel} \u00b7 {version}',
	'dev.channelOff': 'выкл.',
	'dev.channelUnavailableBeta': 'Бета-сервер сейчас недоступен',
	'dev.channelUnavailableProd': 'Сервер PROD сейчас недоступен',
	'dev.channelDisconnectFirst': 'Сначала отключите VPN',
	'dev.version': 'Версия {version}',

	'update.title': 'Доступно обновление',
	'update.text': 'Вышла версия GlukVPN {version}. У вас {current}.',
	'update.action': 'Скачать',
	'update.later': 'Позже',

	'err.tooManyDevices': 'Достигнут лимит устройств. Удалите одно в настройках и повторите.',
	'err.tooManySessions': 'На аккаунте уже есть активный туннель на другом устройстве. Отключите его и повторите.',
	'err.keyRegistered': 'Ключ этого браузера отклонён как уже зарегистрированный. Выпускаем новый ключ — повторите попытку.',
	'err.network': 'Нет связи с сервером.',
	'err.unauthorized': 'Сессия истекла. Войдите заново.',
	'err.forbidden': 'Это устройство больше не разрешено.',
	'err.rateLimited': 'Слишком много попыток. Подождите немного.',
	'err.noNodes': 'Сейчас нет доступного VPN-сервера.',
	'err.noGateway': 'Укажите хост шлюза в расширенных настройках.',
	'err.gatewayUnreachable': 'Шлюз не отвечает.',
	'err.timeout': 'Превышено время ожидания.',
	'err.busy': 'Ещё выполняется предыдущий запрос...',
	'err.unknown': 'Что-то пошло не так.',
	'err.wakeFailed': 'Фон расширения не отвечает. Откройте окно заново.',
	'err.title': 'Ошибка',
	'err.connectTitle': 'Ошибка подключения',
	'err.connectTimeoutText': 'Сервер так и не ответил. Проверьте адрес шлюза в расширенных настройках и повторите.',
	'err.offlineTitle': 'Нет подключения к интернету',
	'err.offlineText': 'Компьютер сейчас офлайн, туннелировать нечего. Подключитесь к сети и повторите.',
	'err.badRequest': 'Сервер отклонил запрос.',
	'err.notFound': 'Не найдено.',
	'err.conflict': 'Это конфликтует с тем, что уже есть на аккаунте.',
	'err.server': 'На сервере сбой. Повторите через минуту.',
	'err.maintenance': 'Сервис кратковременно недоступен. Повторите чуть позже.',
	'err.badCredentials': 'Неверный логин или пароль.',
	'err.accountDisabled': 'Аккаунт отключён. Напишите в поддержку.',
	'err.emailNotVerified': 'Сначала подтвердите адрес электронной почты.',
	'err.noSubscription': 'На аккаунте нет активной подписки.',
	'err.trafficLimit': 'Месячный лимит трафика исчерпан. Подключение заработает снова после сброса лимита.',
	'err.no_pending_connect': 'Слот освобождён. Устройство готово к работе.',
	'err.captcha': 'Проверка капчи не пройдена. Попробуйте снова.',

	'common.none': 'нет',
	'common.retry': 'Повторить',
	'limit.title': 'Достигнут лимит устройств',
	'limit.body': 'Освободите одно место, чтобы зарегистрировать браузер и продолжить.',
	'limit.release': 'Освободить',
	'limit.chooseServer': 'Выбрать сервер',
	'limit.stillFull': 'Лимит устройств всё ещё достигнут.',
	'maintenance.title': 'Технические работы',
	'maintenance.body': 'Туннель безопасно приостановлен. Повторная попытка примерно через {seconds} сек.',
	'map.active': 'Активных: {count} · показано: {placed}',
	'restriction.bittorrent': 'BitTorrent заблокирован',
	'restriction.smtp25': 'SMTP-порт 25 заблокирован',
	'restriction.p2p_ports': 'P2P-порты заблокированы',
	'common.cancel': 'Отмена',
}

export const STRINGS = { en, ru }

/** Returns t(key, vars) with {var} interpolation and an English fallback. */
export function createTranslator(lang) {
	const table = STRINGS[lang] ?? en
	return function t(key, vars) {
		let value = table[key] ?? en[key] ?? key
		if (vars) {
			for (const [name, replacement] of Object.entries(vars)) {
				value = value.split(`{${name}}`).join(String(replacement))
			}
		}
		return value
	}
}

/** Maps a backend error onto a translation key the user can act on. */
export function errorKeyFor(error) {
	const status = Number(error?.statusCode)
	const code = String(error?.code ?? '').toLowerCase()
	const text = `${code} ${String(error?.message ?? '')}`.toLowerCase()

	// Order matters. A 409 used to fall through to "device limit reached", which
	// is why a rejected key and a busy tunnel both showed the wrong advice.
	if (/already registered|public key is already/.test(text)) return 'err.keyRegistered'
	if (/simultaneous|concurrent|another device first|tunnels/.test(text)) {
		return 'err.tooManySessions'
	}
	// Лимит трафика идёт раньше проверки устройств: в обоих случаях встречается
	// слово «limit», а совет «удалите устройство» здесь был бы вредным советом.
	if (/traffic_limit|traffic limit|monthly traffic|allowance/.test(text)) {
		return 'err.trafficLimit'
	}
	if (/device.*(limit|max|too many)|too many devices|device_limit/.test(text)) {
		return 'err.tooManyDevices'
	}
	if (/no_pending_connect|no connection to resume/.test(text)) {
		return 'err.no_pending_connect'
	}
	// ROUND 9: recognise the codes the control plane actually sends, so the user
	// gets a sentence in their own language instead of a relayed English one.
	if (/captcha|turnstile/.test(text)) return 'err.captcha'
	if (/invalid_credentials|bad credentials|wrong password/.test(text)) {
		return 'err.badCredentials'
	}
	if (/account_disabled|user_disabled|suspended/.test(text)) return 'err.accountDisabled'
	if (/email_not_verified|verify your email/.test(text)) return 'err.emailNotVerified'
	if (/no_subscription|subscription_required|no active subscription/.test(text)) {
		return 'err.noSubscription'
	}

	if (status === 0) return 'err.network'
	if (status === 400 || status === 422) return 'err.badRequest'
	if (status === 401) return 'err.unauthorized'
	if (status === 403) return 'err.forbidden'
	if (status === 404) return 'err.notFound'
	if (status === 409) return 'err.conflict'
	if (status === 429) return 'err.rateLimited'
	if (status === 503) return 'err.maintenance'
	if (status >= 500) return 'err.server'
	if (/timeout|timed out|aborted/.test(text)) return 'err.timeout'
	// Deliberately null and not 'err.unknown': the caller decides whether it has
	// a better message of its own before falling back.
	return null
}
