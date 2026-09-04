import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/i18n/app_strings.dart';

/// The "system" language preference: Russian for the CIS locales the product
/// ships to (the same list as the desktop client), English for everything
/// else. Pure, so it needs no platform.
void main() {
  group('LocaleController.resolveSystemLanguage', () {
    test('Russian and the CIS languages resolve to Russian', () {
      for (final String code in <String>['ru', 'kk', 'be', 'uk', 'ky', 'uz']) {
        expect(LocaleController.resolveSystemLanguage(code), same(AppStrings.ru),
            reason: code);
      }
    });

    test('everything else resolves to English', () {
      for (final String code in <String>['en', 'de', 'fr', 'tr', 'zh', 'und']) {
        expect(LocaleController.resolveSystemLanguage(code), same(AppStrings.en),
            reason: code);
      }
      expect(LocaleController.resolveSystemLanguage(''), same(AppStrings.en));
    });

    test('full locale tags and odd casing are read by their language', () {
      expect(LocaleController.resolveSystemLanguage('kk_KZ'), same(AppStrings.ru));
      expect(LocaleController.resolveSystemLanguage('ru-RU'), same(AppStrings.ru));
      expect(LocaleController.resolveSystemLanguage('uz_UZ.UTF-8'),
          same(AppStrings.ru));
      expect(LocaleController.resolveSystemLanguage('RU'), same(AppStrings.ru));
      expect(LocaleController.resolveSystemLanguage('en_US'), same(AppStrings.en));
      expect(LocaleController.resolveSystemLanguage('de_DE.UTF-8'),
          same(AppStrings.en));
    });

    test('an explicit preference always wins over the system', () {
      expect(LocaleController.resolve(AppLanguage.english), same(AppStrings.en));
      expect(LocaleController.resolve(AppLanguage.russian), same(AppStrings.ru));
    });
  });

  group('AppStrings', () {
    test('the two tables are distinct languages', () {
      expect(AppStrings.en.localeCode, 'en');
      expect(AppStrings.ru.localeCode, 'ru');
      expect(AppStrings.ru.isRussian, isTrue);
      expect(AppStrings.en.isRussian, isFalse);
      expect(AppStrings.ru.channelSwitchHint,
          isNot(AppStrings.en.channelSwitchHint));
      expect(AppStrings.ru.betaServerUnavailable, 'Бета-сервер сейчас недоступен');
      expect(AppStrings.en.betaServerUnavailable,
          'The beta server is currently unavailable');
    });

    test('the channel error names the server that did not answer', () {
      expect(AppStrings.en.serverUnavailable(beta: true),
          AppStrings.en.betaServerUnavailable);
      expect(AppStrings.en.serverUnavailable(beta: false),
          AppStrings.en.prodServerUnavailable);
      expect(AppStrings.ru.serverUnavailable(beta: false),
          'Сервер PROD сейчас недоступен');
    });

    test('short dates use the month names of the language', () {
      final DateTime date = DateTime(2026, 9, 12, 12);
      expect(AppStrings.en.shortDate(date), '12 Sep 2026');
      expect(AppStrings.ru.shortDate(date), '12 сен 2026');
      expect(AppStrings.en.shortDate(null), '\u2014');
    });

    test('relative times read naturally in both languages', () {
      final DateTime threeMinutesAgo =
          DateTime.now().subtract(const Duration(minutes: 3));
      expect(AppStrings.en.relativeTime(threeMinutesAgo), '3m ago');
      expect(AppStrings.ru.relativeTime(threeMinutesAgo), '3 мин назад');
      expect(AppStrings.en.relativeTime(null), 'never');
      expect(AppStrings.ru.relativeTime(null), 'никогда');
    });

    test('Russian plural forms for days left', () {
      expect(AppStrings.ru.daysLeft(1), 'день остался');
      expect(AppStrings.ru.daysLeft(3), 'дня осталось');
      expect(AppStrings.ru.daysLeft(11), 'дней осталось');
      expect(AppStrings.ru.daysLeft(21), 'день остался');
      expect(AppStrings.en.daysLeft(1), 'day left');
      expect(AppStrings.en.daysLeft(2), 'days left');
    });
  });
}
