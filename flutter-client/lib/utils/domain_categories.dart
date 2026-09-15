import 'package:flutter/material.dart';

/// Человеческое имя, иконка и цвет для кода категории домена.
///
/// Коды приходят от управляющего сервера
/// (`control-server/src/services/domainCategories.ts`) и выглядят как
/// `streaming-music`, `vpn-control`, `ads` — показывать их человеку нельзя,
/// а именно это и происходило: в разделе «Сайты и категории» стояли сырые
/// английские коды без иконок, и раздел выглядел сломанным.
///
/// Тот же список повторён в расширении (`extension/lib/categories.js`),
/// поэтому телефон, ПК и браузер называют категорию одинаково. Новый код с
/// сервера не ломает экран: незнакомая категория показывается как
/// «Streaming music» с нейтральной иконкой, а не как «Прочее» — врать о
/// содержимом трафика нельзя.
class DomainCategoryStyle {
  const DomainCategoryStyle({
    required this.code,
    required this.ru,
    required this.en,
    required this.icon,
    required this.color,
  });

  final String code;
  final String ru;
  final String en;
  final IconData icon;
  final Color color;

  String label({required bool russian}) => russian ? ru : en;
}

/// Порядок здесь не случаен: он же задаёт порядок показа, если сервер
/// присылает категории без сортировки.
const Map<String, DomainCategoryStyle> domainCategoryStyles =
    <String, DomainCategoryStyle>{
  'video': DomainCategoryStyle(
    code: 'video',
    ru: 'Видео',
    en: 'Video',
    icon: Icons.play_circle_fill_rounded,
    color: Color(0xFFFF6B81),
  ),
  'streaming-music': DomainCategoryStyle(
    code: 'streaming-music',
    ru: 'Музыка',
    en: 'Music',
    icon: Icons.music_note_rounded,
    color: Color(0xFF3DDC97),
  ),
  'social': DomainCategoryStyle(
    code: 'social',
    ru: 'Соцсети',
    en: 'Social',
    icon: Icons.people_alt_rounded,
    color: Color(0xFF6D8BFF),
  ),
  'messaging': DomainCategoryStyle(
    code: 'messaging',
    ru: 'Мессенджеры',
    en: 'Messengers',
    icon: Icons.chat_bubble_rounded,
    color: Color(0xFF4FC3F7),
  ),
  'gaming': DomainCategoryStyle(
    code: 'gaming',
    ru: 'Игры',
    en: 'Gaming',
    icon: Icons.sports_esports_rounded,
    color: Color(0xFFA06BFF),
  ),
  'search': DomainCategoryStyle(
    code: 'search',
    ru: 'Поиск',
    en: 'Search',
    icon: Icons.search_rounded,
    color: Color(0xFFFFC964),
  ),
  'shopping': DomainCategoryStyle(
    code: 'shopping',
    ru: 'Покупки',
    en: 'Shopping',
    icon: Icons.shopping_bag_rounded,
    color: Color(0xFFFFA36B),
  ),
  'cloud': DomainCategoryStyle(
    code: 'cloud',
    ru: 'Облака и сервисы',
    en: 'Cloud services',
    icon: Icons.cloud_rounded,
    color: Color(0xFF8AB4F8),
  ),
  'dev': DomainCategoryStyle(
    code: 'dev',
    ru: 'Разработка',
    en: 'Developer',
    icon: Icons.code_rounded,
    color: Color(0xFF7DE2D1),
  ),
  'ads': DomainCategoryStyle(
    code: 'ads',
    ru: 'Реклама и трекеры',
    en: 'Ads and tracking',
    icon: Icons.campaign_rounded,
    color: Color(0xFFB0BAD6),
  ),
  'adult': DomainCategoryStyle(
    code: 'adult',
    ru: '18+',
    en: 'Adult',
    icon: Icons.visibility_off_rounded,
    color: Color(0xFFD16BA5),
  ),
  'torrent': DomainCategoryStyle(
    code: 'torrent',
    ru: 'Торренты',
    en: 'Torrents',
    icon: Icons.swap_vert_rounded,
    color: Color(0xFF9FE870),
  ),
  'vpn-control': DomainCategoryStyle(
    code: 'vpn-control',
    ru: 'Служебный трафик GlukVPN',
    en: 'GlukVPN service traffic',
    icon: Icons.vpn_key_rounded,
    color: Color(0xFF6D8BFF),
  ),
  'other': DomainCategoryStyle(
    code: 'other',
    ru: 'Прочее',
    en: 'Other',
    icon: Icons.public_rounded,
    color: Color(0xFF8B95B8),
  ),
};

/// Незнакомый код: «streaming-music» -> «Streaming music».
///
/// Показываем его как есть, потому что подписать чужой трафик «прочим» —
/// это тихо соврать о том, что человек видит в статистике.
String _humanise(String code) {
  final String cleaned = code.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  if (cleaned.isEmpty) return code;
  return cleaned[0].toUpperCase() + cleaned.substring(1);
}

/// Оформление для кода категории. Никогда не возвращает null.
DomainCategoryStyle domainCategoryStyle(String? code) {
  final String key = (code ?? '').trim().toLowerCase();
  if (key.isEmpty) return domainCategoryStyles['other']!;
  final DomainCategoryStyle? known = domainCategoryStyles[key];
  if (known != null) return known;
  final String human = _humanise(key);
  return DomainCategoryStyle(
    code: key,
    ru: human,
    en: human,
    icon: Icons.label_rounded,
    color: const Color(0xFF8B95B8),
  );
}

/// Короткая подпись категории на языке интерфейса.
String domainCategoryLabel(String? code, {required bool russian}) =>
    domainCategoryStyle(code).label(russian: russian);
