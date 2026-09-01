import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/secure_store.dart';

/// ROUND 11: the phone speaks Russian and English.
///
/// The desktop client has had `desktop_strings.dart` since round 4; the mobile
/// app was hard-coded English, which is the wrong default for an audience that
/// is mostly Russian-speaking. This file is the mobile counterpart.
///
/// Deliberately not `flutter_localizations` + ARB. That machinery buys plural
/// rules, date formats and RTL, none of which this app needs for two languages
/// that both use Latin/Cyrillic LTR text; what it costs is a code-generation
/// step in a build that currently has none. A const table is checked by the
/// compiler just as strictly: every field is `required`, so a string added to
/// one language and forgotten in the other will not compile.
enum AppLanguage {
	/// Follow the phone. The default, and what most people should stay on.
	system('system'),
	english('en'),
	russian('ru');

	const AppLanguage(this.id);

	/// Stored value. Never sent to the server.
	final String id;

	static AppLanguage fromId(String? id) => AppLanguage.values.firstWhere(
				(AppLanguage value) => value.id == id,
				orElse: () => AppLanguage.system,
			);
}

/// Every user-visible string on the phone, in one place per language.
class AppStrings {
	const AppStrings({
		required this.code,
		required this.languageName,
		// --- shared ---
		required this.back,
		required this.cancel,
		required this.save,
		required this.copy,
		required this.copied,
		required this.refresh,
		required this.reload,
		required this.revoke,
		required this.revoking,
		required this.somethingWentWrong,
		required this.notSet,
		required this.unknownPlatform,
		// --- sign in ---
		required this.welcomeBack,
		required this.signInSubtitle,
		required this.usernameOrEmail,
		required this.password,
		required this.showPassword,
		required this.hidePassword,
		required this.signIn,
		required this.orContinueWith,
		required this.createAccount,
		required this.forgotPassword,
		required this.enterUsernameOrEmail,
		required this.enterValidEmail,
		required this.enterPassword,
		required this.enterEmail,
		// --- telegram sign in ---
		required this.telegram,
		required this.google,
		required this.telegramSignInTitle,
		required this.telegramSignInBody,
		required this.telegramOpenBot,
		required this.telegramWaiting,
		required this.telegramCannotOpen,
		required this.telegramDenied,
		required this.telegramExpired,
		required this.confirmationCode,
		// --- sign up ---
		required this.createAccountTitle,
		required this.registerSubtitle,
		required this.email,
		required this.repeatPassword,
		required this.repeatIt,
		required this.continueLabel,
		required this.passwordsDoNotMatch,
		required this.weSentACodeTo,
		required this.codeFromEmail,
		required this.confirm,
		required this.resend,
		required this.mailNotDelivered,
		required this.codeIsSixDigits,
		required this.emailConfirmed,
		required this.lastStepTelegram,
		required this.openTelegram,
		required this.telegramFallbackHint,
		required this.linkToBot,
		required this.codeForBot,
		required this.waitingForConfirmation,
		required this.stoppedChecking,
		required this.accountReady,
		required this.yourUsername,
		required this.signInWithEither,
		required this.goToSignIn,
		required this.signUpClosed,
		required this.signUpClosedTelegram,
		required this.registrationAlwaysProd,
		required this.termsNotice,
		// --- recovery ---
		required this.recoverTitle,
		required this.recoverSubtitle,
		required this.whereToSendCode,
		required this.sendTheCode,
		required this.codeSentByEmail,
		required this.codeSentByTelegram,
		required this.code,
		required this.newPassword,
		required this.savePasswordLabel,
		required this.passwordChanged,
		required this.passwordChangedBody,
		// --- settings ---
		required this.settings,
		required this.account,
		required this.accountTileSubtitle,
		required this.myDevices,
		required this.notRegisteredYet,
		required this.animations,
		required this.fullMotion,
		required this.full,
		required this.reduced,
		required this.appearance,
		required this.language,
		required this.languageAuto,
		required this.internal,
		required this.channel,
		required this.diagnostics,
		required this.accountingNotice,
		required this.signOut,
		required this.signOutQuestion,
		required this.signOutBody,
		required this.production,
		required this.beta,
		required this.usingBeta,
		required this.usingProduction,
		required this.channelLockedWhileConnected,
		required this.channelExplainer,
		required this.betaNotAnswering,
		required this.channelAdminOnly,
		required this.unreachable,
		required this.off,
		// --- account ---
		required this.profile,
		required this.username,
		required this.nickname,
		required this.changeNickname,
		required this.verified,
		required this.unverified,
		required this.accountNumber,
		required this.accountIdCopied,
		required this.status,
		required this.signedUpFrom,
		required this.memberSince,
		required this.subscription,
		required this.active,
		required this.none,
		required this.validUntil,
		required this.deviceSlots,
		required this.tunnelsAtOnce,
		required this.noActivePlanBody,
		required this.security,
		required this.changePassword,
		required this.changeEmail,
		required this.currentPassword,
		required this.telegramAccount,
		required this.telegramLinkAction,
		required this.telegramRelinkAction,
		required this.telegramLinkBody,
		required this.passwordChangedSignedOut,
		required this.emailCodeSent,
		required this.emailChanged,
		required this.premium,
		required this.renews,
		required this.devicesShort,
		required this.atOnce,
		required this.upTo,
		required this.noActivePlan,
		required this.nicknameChangesIdDoesNot,
		// --- devices ---
		required this.devices,
		required this.noDevicesRegistered,
		required this.thisDevice,
		required this.revoked,
		required this.signedIn,
		required this.lastSeen,
		required this.registeredOn,
		required this.revokeQuestion,
		required this.revokeCurrentBody,
		required this.revokeOtherBody,
		required this.revokeNotice,
		// --- update banner ---
		required this.updateAvailable,
		required this.updateRequired,
		required this.download,
		required this.later,
		// --- session state ---
		required this.showingLastKnownState,
		required this.sessionExpired,
	});

	/// BCP-47 language subtag, also used as the `Locale` code.
	final String code;

	/// Endonym, so the picker reads the same in either language.
	final String languageName;

	bool get isRussian => code == 'ru';

	// --- shared ---
	final String back;
	final String cancel;
	final String save;
	final String copy;
	final String copied;
	final String refresh;
	final String reload;
	final String revoke;
	final String revoking;
	final String somethingWentWrong;
	final String notSet;
	final String unknownPlatform;

	// --- sign in ---
	final String welcomeBack;
	final String signInSubtitle;
	final String usernameOrEmail;
	final String password;
	final String showPassword;
	final String hidePassword;
	final String signIn;
	final String orContinueWith;
	final String createAccount;
	final String forgotPassword;
	final String enterUsernameOrEmail;
	final String enterValidEmail;
	final String enterPassword;
	final String enterEmail;

	// --- telegram sign in ---
	final String telegram;
	final String google;
	final String telegramSignInTitle;
	final String telegramSignInBody;
	final String telegramOpenBot;
	final String telegramWaiting;
	final String telegramCannotOpen;
	final String telegramDenied;
	final String telegramExpired;
	final String confirmationCode;

	// --- sign up ---
	final String createAccountTitle;
	final String registerSubtitle;
	final String email;
	final String repeatPassword;
	final String repeatIt;
	final String continueLabel;
	final String passwordsDoNotMatch;
	final String weSentACodeTo;
	final String codeFromEmail;
	final String confirm;
	final String resend;
	final String mailNotDelivered;
	final String codeIsSixDigits;
	final String emailConfirmed;
	final String lastStepTelegram;
	final String openTelegram;
	final String telegramFallbackHint;
	final String linkToBot;
	final String codeForBot;
	final String waitingForConfirmation;
	final String stoppedChecking;
	final String accountReady;
	final String yourUsername;
	final String signInWithEither;
	final String goToSignIn;
	final String signUpClosed;
	final String signUpClosedTelegram;
	final String registrationAlwaysProd;
	final String termsNotice;

	// --- recovery ---
	final String recoverTitle;
	final String recoverSubtitle;
	final String whereToSendCode;
	final String sendTheCode;
	final String codeSentByEmail;
	final String codeSentByTelegram;
	final String code;
	final String newPassword;
	final String savePasswordLabel;
	final String passwordChanged;
	final String passwordChangedBody;

	// --- settings ---
	final String settings;
	final String account;
	final String accountTileSubtitle;
	final String myDevices;
	final String notRegisteredYet;
	final String animations;
	final String fullMotion;
	final String full;
	final String reduced;
	final String appearance;
	final String language;
	final String languageAuto;
	final String internal;
	final String channel;
	final String diagnostics;
	final String accountingNotice;
	final String signOut;
	final String signOutQuestion;
	final String signOutBody;
	final String production;
	final String beta;
	final String usingBeta;
	final String usingProduction;
	final String channelLockedWhileConnected;
	final String channelExplainer;
	final String betaNotAnswering;
	final String channelAdminOnly;
	final String unreachable;
	final String off;

	// --- account ---
	final String profile;
	final String username;
	final String nickname;
	final String changeNickname;
	final String verified;
	final String unverified;
	final String accountNumber;
	final String accountIdCopied;
	final String status;
	final String signedUpFrom;
	final String memberSince;
	final String subscription;
	final String active;
	final String none;
	final String validUntil;
	final String deviceSlots;
	final String tunnelsAtOnce;
	final String noActivePlanBody;
	final String security;
	final String changePassword;
	final String changeEmail;
	final String currentPassword;
	final String telegramAccount;
	final String telegramLinkAction;
	final String telegramRelinkAction;
	final String telegramLinkBody;
	final String passwordChangedSignedOut;
	final String emailCodeSent;
	final String emailChanged;
	final String premium;
	final String renews;
	final String devicesShort;
	final String atOnce;
	final String upTo;
	final String noActivePlan;
	final String nicknameChangesIdDoesNot;

	// --- devices ---
	final String devices;
	final String noDevicesRegistered;
	final String thisDevice;
	final String revoked;
	final String signedIn;
	final String lastSeen;
	final String registeredOn;
	final String revokeQuestion;
	final String revokeCurrentBody;
	final String revokeOtherBody;
	final String revokeNotice;

	// --- update banner ---
	final String updateAvailable;
	final String updateRequired;
	final String download;
	final String later;

	// --- session state ---
	final String showingLastKnownState;
	final String sessionExpired;

	// --- parameterised -------------------------------------------------------
	//
	// Anything that interpolates a number or a name is a method rather than a
	// field, so the two languages can put the value in different places instead
	// of being forced into English word order.

	String atLeastChars(int n) =>
			isRussian ? 'Минимум $n символов' : 'At least $n characters';

	String atMostChars(int n) =>
			isRussian ? 'Не больше $n символов' : 'At most $n characters';

	String codeValidFor(int minutes) => isRussian
			? 'Код действует $minutes мин.'
			: 'It is valid for $minutes minutes.';

	String openBotAndShareContact(String handle) => isRussian
			? 'Откройте $handle и нажмите кнопку «Поделиться контактом». Именно это '
					'отличает живого человека от сотни одноразовых адресов.'
			: 'Open $handle in Telegram and press the button that shares your '
					'contact. That is what tells one real person apart from a hundred '
					'throwaway addresses.';

	String slotsInUse(int used, int total) => isRussian
			? 'Занято $used из $total мест'
			: '$used of $total device slots in use';

	String usedOfTotal(int used, int total) =>
			isRussian ? '$used из $total' : '$used of $total in use';

	String tunnelsCount(int n) => isRussian
			? '$n ${n == 1 ? 'туннель' : (n < 5 ? 'туннеля' : 'туннелей')}'
			: '$n tunnel${n == 1 ? '' : 's'}';

	String daysLeft(int n) {
		if (!isRussian) return n == 1 ? 'day left' : 'days left';
		final int last = n % 10;
		final int tens = n % 100;
		if (tens >= 11 && tens <= 14) return 'дней осталось';
		if (last == 1) return 'день остался';
		if (last >= 2 && last <= 4) return 'дня осталось';
		return 'дней осталось';
	}

	String connectedVia(String node) =>
			isRussian ? 'Подключено через $node' : 'Connected via $node';

	String revokeDeviceTitle(String name) =>
			isRussian ? 'Отозвать «$name»?' : 'Revoke $name?';

	String upToDevices(int n) => isRussian ? 'до $n на тарифе' : 'up to $n on the plan';

	String thisDeviceIs(String name) =>
			isRussian ? 'Это устройство: $name' : 'This device: $name';

	String nicknameIsNow(String name) =>
			isRussian ? 'Ник теперь $name' : 'Nickname is now $name';

	String newVersion(String version) =>
			isRussian ? 'Доступна версия $version' : 'Version $version is available';

	String resendIn(int seconds) => isRussian
			? 'Код отправлен — подождите $seconds с'
			: 'Code sent \u2014 wait $seconds s';

	// -------------------------------------------------------------------------

	static const AppStrings en = AppStrings(
		code: 'en',
		languageName: 'English',
		back: 'Back',
		cancel: 'Cancel',
		save: 'Save',
		copy: 'Copy',
		copied: 'Copied',
		refresh: 'Refresh',
		reload: 'Reload',
		revoke: 'Revoke',
		revoking: 'Revoking\u2026',
		somethingWentWrong: 'Something went wrong. Please try again.',
		notSet: 'not set',
		unknownPlatform: 'unknown platform',
		welcomeBack: 'Welcome back',
		signInSubtitle: 'Sign in to pick a country and connect.',
		usernameOrEmail: 'Username or email',
		password: 'Password',
		showPassword: 'Show password',
		hidePassword: 'Hide password',
		signIn: 'Sign In',
		orContinueWith: 'or continue with',
		createAccount: 'Create an account',
		forgotPassword: 'Forgot your password?',
		enterUsernameOrEmail: 'Enter your username or email',
		enterValidEmail: 'Enter a valid email address',
		enterPassword: 'Enter your password',
		enterEmail: 'Enter your email address',
		telegram: 'Telegram',
		google: 'Google',
		telegramSignInTitle: 'Sign in through Telegram',
		telegramSignInBody:
				'The bot will ask you to confirm this sign-in. Come back here once you '
				'have pressed the button in Telegram \u2014 this screen finishes by '
				'itself.',
		telegramOpenBot: 'Open the bot',
		telegramWaiting: 'Waiting for your confirmation in Telegram\u2026',
		telegramCannotOpen:
				'Telegram would not open. The link has been copied \u2014 paste it into '
				'a browser or into the Telegram search box.',
		telegramDenied: 'The sign-in request was declined in Telegram.',
		telegramExpired: 'This sign-in link expired. Please try again.',
		confirmationCode: 'Confirmation code',
		createAccountTitle: 'Create an account',
		registerSubtitle:
				'Email and password, a code from the email, then a confirmation in '
				'Telegram \u2014 three steps.',
		email: 'Email',
		repeatPassword: 'Repeat the password',
		repeatIt: 'Once more',
		continueLabel: 'Continue',
		passwordsDoNotMatch: 'The passwords do not match',
		weSentACodeTo: 'We sent a 6-digit code to',
		codeFromEmail: 'Code from the email',
		confirm: 'Confirm',
		resend: 'Resend the code',
		mailNotDelivered:
				'The email could not be sent. Try Resend, or write to support if it '
				'keeps failing.',
		codeIsSixDigits: 'The code is 6 digits.',
		emailConfirmed: 'Email confirmed.',
		lastStepTelegram: 'Last step \u2014 Telegram',
		openTelegram: 'Open Telegram',
		telegramFallbackHint:
				'If the bot did not open, find it in Telegram and send it this code:',
		linkToBot: 'Link to the bot',
		codeForBot: 'Code for the bot',
		waitingForConfirmation:
				'Waiting for the confirmation. This screen updates by itself.',
		stoppedChecking:
				'Stopped checking. Reopen this screen if you already confirmed in '
				'Telegram.',
		accountReady: 'The account is ready',
		yourUsername: 'Your username',
		signInWithEither:
				'Sign in with this username or with your email address \u2014 either '
				'one works.',
		goToSignIn: 'Go to sign in',
		signUpClosed:
				'Sign-up is closed at the moment. Message us and we will open access '
				'by hand.',
		signUpClosedTelegram:
				'Telegram confirmation is unavailable right now, so sign-up is closed. '
				'Message us and we will open access by hand.',
		registrationAlwaysProd:
				'The account is always created on the main GlukVPN servers, even if '
				'this build is pointed at beta.',
		termsNotice:
				'By continuing you accept the terms of use and the privacy policy.',
		recoverTitle: 'Recover access',
		recoverSubtitle:
				'We send a code to your email or to Telegram \u2014 whichever is easier.',
		whereToSendCode: 'Where should the code go?',
		sendTheCode: 'Send the code',
		codeSentByEmail: 'The code was sent by email.',
		codeSentByTelegram: 'The code was sent to Telegram.',
		code: 'Code',
		newPassword: 'New password',
		savePasswordLabel: 'Save the password',
		passwordChanged: 'The password is changed',
		passwordChangedBody:
				'Every other session was signed out, so anybody who had the old '
				'password is out too.',
		settings: 'Settings',
		account: 'Account',
		accountTileSubtitle: 'Profile, email, password and Telegram',
		myDevices: 'My devices',
		notRegisteredYet: 'not registered yet',
		animations: 'Animations',
		fullMotion: 'Full motion',
		full: 'full',
		reduced: 'reduced',
		appearance: 'Appearance',
		language: 'Language',
		languageAuto: 'Automatic',
		internal: 'Internal',
		channel: 'Channel',
		diagnostics: 'Diagnostics',
		accountingNotice:
				'Traffic accounting records only byte counters and session times '
				'\u2014 never addresses, URLs or payloads.',
		signOut: 'Sign out',
		signOutQuestion: 'Sign out?',
		signOutBody:
				'The tunnel is closed, this device is revoked on the server and its '
				'peer is removed from the node.',
		production: 'Production',
		beta: 'Beta',
		usingBeta: 'Using BETA',
		usingProduction: 'Using PRODUCTION',
		channelLockedWhileConnected:
				'Disconnect first: switching channel while a tunnel is up would leave '
				'a peer installed on a node this app can no longer reach.',
		channelExplainer:
				'BETA is a separate deployment: its own database, its own WireGuard '
				'node and its own accounts. Your PROD session stays signed in.',
		betaNotAnswering: 'BETA is not answering right now',
		channelAdminOnly:
				'The channel switch belongs to administrator accounts. Everybody else '
				'is on production, which is the only place their account exists.',
		unreachable: 'unreachable',
		off: 'off',
		profile: 'Profile',
		username: 'Username',
		nickname: 'Nickname',
		changeNickname: 'Change nickname',
		verified: 'verified',
		unverified: 'unverified',
		accountNumber: 'Account number',
		accountIdCopied: 'Account ID copied',
		status: 'Status',
		signedUpFrom: 'Signed up from',
		memberSince: 'Member since',
		subscription: 'Subscription',
		active: 'active',
		none: 'none',
		validUntil: 'Valid until',
		deviceSlots: 'Device slots',
		tunnelsAtOnce: 'Tunnels at once',
		noActivePlanBody:
				'Without an active plan the servers refuse new tunnels. Nothing on the '
				'account is deleted.',
		security: 'Security',
		changePassword: 'Change password',
		changeEmail: 'Change email',
		currentPassword: 'Current password',
		telegramAccount: 'Telegram',
		telegramLinkAction: 'Link Telegram',
		telegramRelinkAction: 'Re-link Telegram',
		telegramLinkBody:
				'Open the bot and share your contact. The number is only used so that '
				'one person has one account.',
		passwordChangedSignedOut:
				'Password changed. Every other session was signed out.',
		emailCodeSent: 'A code was sent to the new address.',
		emailChanged: 'The email address is updated.',
		premium: 'Premium',
		renews: 'Renews',
		devicesShort: 'Devices',
		atOnce: 'At once',
		upTo: 'up to',
		noActivePlan: 'No active plan',
		nicknameChangesIdDoesNot:
				'Nickname can change, this number never does',
		devices: 'Devices',
		noDevicesRegistered: 'No devices registered.',
		thisDevice: 'this device',
		revoked: 'Revoked',
		signedIn: 'Signed in',
		lastSeen: 'last seen',
		registeredOn: 'registered',
		revokeQuestion: 'Revoke this device?',
		revokeCurrentBody:
				'This is the phone you are holding. The tunnel is closed, the '
				'WireGuard peer is removed from the node and a fresh key pair is '
				'registered right away, so you stay signed in.',
		revokeOtherBody:
				'The session is closed and the WireGuard peer is removed from the '
				'node. That device has to sign in again.',
		revokeNotice:
				'Revoking closes the tunnel and removes the WireGuard peer from the '
				'node. Byte counters and session times are kept for accounting '
				'\u2014 addresses and payloads never are.',
		updateAvailable: 'Update available',
		updateRequired: 'Update required',
		download: 'Download',
		later: 'Later',
		showingLastKnownState:
				'Showing the last known state \u2014 the server has not confirmed this '
				'session yet.',
		sessionExpired: 'Session expired. Please sign in again.',
	);

	static const AppStrings ru = AppStrings(
		code: 'ru',
		languageName: 'Русский',
		back: 'Назад',
		cancel: 'Отмена',
		save: 'Сохранить',
		copy: 'Копировать',
		copied: 'Скопировано',
		refresh: 'Обновить',
		reload: 'Обновить',
		revoke: 'Отозвать',
		revoking: 'Отзываем\u2026',
		somethingWentWrong: 'Что-то пошло не так. Попробуйте ещё раз.',
		notSet: 'не указана',
		unknownPlatform: 'платформа неизвестна',
		welcomeBack: 'С возвращением',
		signInSubtitle: 'Войдите, чтобы выбрать страну и подключиться.',
		usernameOrEmail: 'Логин или email',
		password: 'Пароль',
		showPassword: 'Показать пароль',
		hidePassword: 'Скрыть пароль',
		signIn: 'Войти',
		orContinueWith: 'или войдите через',
		createAccount: 'Создать аккаунт',
		forgotPassword: 'Забыли пароль?',
		enterUsernameOrEmail: 'Введите логин или почту',
		enterValidEmail: 'Введите корректный адрес почты',
		enterPassword: 'Введите пароль',
		enterEmail: 'Введите адрес почты',
		telegram: 'Telegram',
		google: 'Google',
		telegramSignInTitle: 'Вход через Telegram',
		telegramSignInBody:
				'Бот попросит подтвердить этот вход. Вернитесь сюда после того, как '
				'нажмёте кнопку в Telegram \u2014 экран закроется сам.',
		telegramOpenBot: 'Открыть бота',
		telegramWaiting: 'Ждём подтверждения в Telegram\u2026',
		telegramCannotOpen:
				'Telegram не открылся. Ссылка скопирована \u2014 вставьте её в браузер '
				'или в поиск Telegram.',
		telegramDenied: 'Вход отклонён в Telegram.',
		telegramExpired: 'Ссылка для входа истекла. Попробуйте ещё раз.',
		confirmationCode: 'Код подтверждения',
		createAccountTitle: 'Регистрация',
		registerSubtitle:
				'Почта и пароль, код из письма, затем подтверждение в Telegram '
				'\u2014 три шага.',
		email: 'Email',
		repeatPassword: 'Повторите пароль',
		repeatIt: 'Ещё раз',
		continueLabel: 'Продолжить',
		passwordsDoNotMatch: 'Пароли не совпадают',
		weSentACodeTo: 'Мы отправили код из 6 цифр на',
		codeFromEmail: 'Код из письма',
		confirm: 'Подтвердить',
		resend: 'Отправить код ещё раз',
		mailNotDelivered:
				'Письмо отправить не удалось. Попробуйте ещё раз или напишите в '
				'поддержку.',
		codeIsSixDigits: 'Код состоит из 6 цифр.',
		emailConfirmed: 'Почта подтверждена.',
		lastStepTelegram: 'Последний шаг \u2014 Telegram',
		openTelegram: 'Открыть Telegram',
		telegramFallbackHint:
				'Если бот не открылся сам \u2014 найдите его в Telegram и отправьте '
				'этот код:',
		linkToBot: 'Ссылка на бота',
		codeForBot: 'Код для бота',
		waitingForConfirmation:
				'Ждём подтверждения. Экран обновится сам.',
		stoppedChecking:
				'Проверка остановлена. Откройте экран заново, если уже подтвердили в '
				'Telegram.',
		accountReady: 'Аккаунт создан',
		yourUsername: 'Ваш логин',
		signInWithEither:
				'Войти можно и по логину, и по почте \u2014 работает и то, и другое.',
		goToSignIn: 'Перейти ко входу',
		signUpClosed:
				'Регистрация сейчас закрыта. Напишите нам \u2014 откроем доступ вручную.',
		signUpClosedTelegram:
				'Подтверждение через Telegram сейчас недоступно, поэтому регистрация '
				'закрыта. Напишите нам \u2014 откроем доступ вручную.',
		registrationAlwaysProd:
				'Аккаунт всегда создаётся на основных серверах GlukVPN, даже если эта '
				'сборка смотрит на бету.',
		termsNotice:
				'Продолжая, вы соглашаетесь с условиями использования и политикой '
				'конфиденциальности.',
		recoverTitle: 'Восстановление доступа',
		recoverSubtitle:
				'Пришлём код на почту или в Telegram \u2014 как вам удобнее.',
		whereToSendCode: 'Куда прислать код',
		sendTheCode: 'Прислать код',
		codeSentByEmail: 'Код отправлен на почту.',
		codeSentByTelegram: 'Код отправлен в Telegram.',
		code: 'Код',
		newPassword: 'Новый пароль',
		savePasswordLabel: 'Сохранить пароль',
		passwordChanged: 'Пароль обновлён',
		passwordChangedBody:
				'Все остальные сессии завершены, так что тот, кто знал старый пароль, '
				'больше не войдёт.',
		settings: 'Настройки',
		account: 'Аккаунт',
		accountTileSubtitle: 'Профиль, почта, пароль и Telegram',
		myDevices: 'Мои устройства',
		notRegisteredYet: 'ещё не зарегистрировано',
		animations: 'Анимации',
		fullMotion: 'Полные',
		full: 'полные',
		reduced: 'сокращённые',
		appearance: 'Оформление',
		language: 'Язык',
		languageAuto: 'Как в системе',
		internal: 'Служебное',
		channel: 'Канал',
		diagnostics: 'Диагностика',
		accountingNotice:
				'В учёте трафика хранятся только счётчики байтов и время сессий '
				'\u2014 ни адресов, ни ссылок, ни содержимого.',
		signOut: 'Выйти',
		signOutQuestion: 'Выйти из аккаунта?',
		signOutBody:
				'Туннель закроется, устройство будет отозвано на сервере, а его peer '
				'удалён с ноды.',
		production: 'Продакшн',
		beta: 'Бета',
		usingBeta: 'Используется БЕТА',
		usingProduction: 'Используется ПРОДАКШН',
		channelLockedWhileConnected:
				'Сначала отключитесь: смена канала при поднятом туннеле оставит peer '
				'на ноде, до которой приложение больше не достучится.',
		channelExplainer:
				'БЕТА \u2014 отдельный стенд: своя база, своя нода WireGuard и свои '
				'аккаунты. Сессия на ПРОДЕ остаётся активной.',
		betaNotAnswering: 'БЕТА сейчас не отвечает',
		channelAdminOnly:
				'Переключение канала доступно только администраторам. Всем остальным '
				'\u2014 продакшн, единственное место, где существует их аккаунт.',
		unreachable: 'недоступен',
		off: 'выключена',
		profile: 'Профиль',
		username: 'Логин',
		nickname: 'Ник',
		changeNickname: 'Сменить ник',
		verified: 'подтверждена',
		unverified: 'не подтверждена',
		accountNumber: 'Номер аккаунта',
		accountIdCopied: 'Номер аккаунта скопирован',
		status: 'Статус',
		signedUpFrom: 'Регистрация из',
		memberSince: 'С нами с',
		subscription: 'Подписка',
		active: 'активна',
		none: 'нет',
		validUntil: 'Действует до',
		deviceSlots: 'Устройства',
		tunnelsAtOnce: 'Туннелей одновременно',
		noActivePlanBody:
				'Без активной подписки серверы не поднимают новые туннели. Ничего в '
				'аккаунте при этом не удаляется.',
		security: 'Безопасность',
		changePassword: 'Сменить пароль',
		changeEmail: 'Сменить почту',
		currentPassword: 'Текущий пароль',
		telegramAccount: 'Telegram',
		telegramLinkAction: 'Привязать Telegram',
		telegramRelinkAction: 'Перепривязать Telegram',
		telegramLinkBody:
				'Откройте бота и поделитесь контактом. Номер нужен только для того, '
				'чтобы на одного человека был один аккаунт.',
		passwordChangedSignedOut:
				'Пароль изменён. Все остальные сессии завершены.',
		emailCodeSent: 'Код отправлен на новый адрес.',
		emailChanged: 'Адрес почты обновлён.',
		premium: 'Premium',
		renews: 'Продление',
		devicesShort: 'Устройства',
		atOnce: 'Одновременно',
		upTo: 'до',
		noActivePlan: 'Подписки нет',
		nicknameChangesIdDoesNot: 'Ник можно менять, номер \u2014 никогда',
		devices: 'Устройства',
		noDevicesRegistered: 'Устройств пока нет.',
		thisDevice: 'это устройство',
		revoked: 'Отозвано',
		signedIn: 'В сети',
		lastSeen: 'последний раз',
		registeredOn: 'добавлено',
		revokeQuestion: 'Отозвать устройство?',
		revokeCurrentBody:
				'Это устройство, с которого вы сейчас смотрите. Туннель закроется, '
				'peer будет удалён с ноды, а новая пара ключей зарегистрируется сразу '
				'\u2014 из аккаунта вас не выкинет.',
		revokeOtherBody:
				'Сессия закроется, а peer WireGuard будет удалён с ноды. На том '
				'устройстве придётся войти заново.',
		revokeNotice:
				'Отзыв закрывает туннель и удаляет peer WireGuard с ноды. Счётчики '
				'байтов и время сессий сохраняются для учёта \u2014 адреса и '
				'содержимое не сохраняются никогда.',
		updateAvailable: 'Доступно обновление',
		updateRequired: 'Требуется обновление',
		download: 'Скачать',
		later: 'Позже',
		showingLastKnownState:
				'Показано последнее известное состояние \u2014 сервер ещё не '
				'подтвердил эту сессию.',
		sessionExpired: 'Сессия истекла. Войдите заново.',
	);
}

/// Holds the language preference and hands out the matching [AppStrings].
///
/// The preference is persisted, the *resolution* is not: somebody who leaves it
/// on `system` and changes their phone to Russian gets Russian on the next
/// launch without this class remembering anything about it.
class LocaleController extends ChangeNotifier {
	LocaleController({required SecureStore store}) : _store = store;

	final SecureStore _store;

	AppLanguage _preference = AppLanguage.system;

	AppLanguage get preference => _preference;

	AppStrings get strings => resolve(_preference);

	Locale get locale => Locale(strings.code);

	/// Label for the settings row: "Automatic (Русский)" is more useful than
	/// "Automatic" on its own, because it says what automatic actually picked.
	String get preferenceLabel {
		switch (_preference) {
			case AppLanguage.system:
				return '${strings.languageAuto} \u00b7 ${systemDefault.languageName}';
			case AppLanguage.english:
				return AppStrings.en.languageName;
			case AppLanguage.russian:
				return AppStrings.ru.languageName;
		}
	}

	static AppStrings resolve(AppLanguage preference) {
		switch (preference) {
			case AppLanguage.english:
				return AppStrings.en;
			case AppLanguage.russian:
				return AppStrings.ru;
			case AppLanguage.system:
				return systemDefault;
		}
	}

	/// What the phone asks for. Anything that is not Russian falls back to
	/// English rather than to the first supported locale, because English is the
	/// language a non-Russian speaker is most likely to read.
	static AppStrings get systemDefault {
		final String code =
				PlatformDispatcher.instance.locale.languageCode.toLowerCase();
		return code == 'ru' ? AppStrings.ru : AppStrings.en;
	}

	Future<void> restore() async {
		_preference = AppLanguage.fromId(await _store.readLanguage());
		notifyListeners();
	}

	Future<void> select(AppLanguage next) async {
		if (next == _preference) return;
		_preference = next;
		notifyListeners();
		await _store.writeLanguage(next.id);
	}
}

/// `context.strings.signIn` instead of
/// `context.watch<LocaleController>().strings.signIn` at every call site.
extension LocalisedContext on BuildContext {
	AppStrings get strings => watch<LocaleController>().strings;
}
