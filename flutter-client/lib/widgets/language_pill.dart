import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../theme/tokens.dart';

/// The language chooser: System / English / Русский.
///
/// One dialog for the whole app. Settings had it as a private method, which
/// meant the sign-in screen could not offer the same choice without a copy.
/// Now the pill on onboarding and the row in Settings open exactly this.
///
/// Three choices, not two. "System" has to exist and has to be the default,
/// because the app should follow the phone for anyone who never opens this.
/// Picking a language explicitly pins it, so a Russian phone can run the app
/// in English and the other way round.
Future<void> showLanguageChooser(
  BuildContext context,
  LocaleController locale,
) async {
  final AppStrings s = context.read<LocaleController>().strings;
  final AppLanguage? picked = await showDialog<AppLanguage>(
    context: context,
    builder: (BuildContext context) => SimpleDialog(
      backgroundColor: GlukColors.bg,
      title: Text(s.language),
      children: <Widget>[
        for (final AppLanguage option in AppLanguage.values)
          RadioListTile<AppLanguage>(
            value: option,
            groupValue: locale.preference,
            title: Text(languageLabel(option, s)),
            onChanged: (AppLanguage? value) =>
                Navigator.of(context).pop(value),
          ),
      ],
    ),
  );
  if (picked != null) await locale.select(picked);
}

/// The two real languages are written in their own language - a person looking
/// for Russian is looking for "Русский", not for "Russian".
String languageLabel(AppLanguage option, AppStrings s) {
  switch (option) {
    case AppLanguage.system:
      return s.languageAuto;
    case AppLanguage.english:
      return AppStrings.en.languageName;
    case AppLanguage.russian:
      return AppStrings.ru.languageName;
  }
}

/// A small globe-and-code pill ("RU" / "EN") that opens [showLanguageChooser].
///
/// Sits in the top-right corner of onboarding and sign-in, so the language can
/// be changed before anybody has an account - the Settings row is behind a
/// login, which is exactly where a person who cannot read the screen is not.
/// Drives [LocaleController], so the whole app switches at once.
class LanguagePill extends StatelessWidget {
  const LanguagePill({super.key});

  @override
  Widget build(BuildContext context) {
    final LocaleController locale = context.watch<LocaleController>();
    final AppStrings s = locale.strings;
    final TextTheme text = Theme.of(context).textTheme;

    return Tooltip(
      message: s.language,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showLanguageChooser(context, locale),
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
            decoration: BoxDecoration(
              color: GlukColors.glass,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: GlukColors.stroke),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  Icons.language_rounded,
                  size: 14,
                  color: GlukColors.violetLight,
                ),
                const SizedBox(width: 6),
                Text(
                  s.localeCode.toUpperCase(),
                  style: text.labelSmall?.copyWith(
                    color: GlukColors.text0,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
