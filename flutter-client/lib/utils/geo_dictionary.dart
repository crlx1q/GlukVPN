/// Localised geography for server labels: the Flutter mirror of
/// `extension/lib/geo.js`.
///
/// HOW TO ADD A NEW LOCATION (the same three steps as in the extension):
///
///   1. Country code in [geoCountries]:
///        'NL': LocalizedName('Нидерланды', 'Netherlands'),
///   2. City in [geoCities]:
///        'amsterdam': LocalizedName('Амстердам', 'Amsterdam'),
///   3. Map coordinates in [cityCoords]:
///        'amsterdam': GeoPoint(52.37, 4.9),
///
/// Nothing else is needed. The server appears translated in the desktop app,
/// in the phone app and in the browser extension, and its dot lands in the
/// right place on the map.
///
/// Keep this file and `extension/lib/geo.js` in step. They are the same
/// dictionary in two languages, and a server that is only in one of them shows
/// up as a bare country code ("DE") on the other platform.
library;

/// One name in both interface languages.
class LocalizedName {
  const LocalizedName(this.ru, this.en);

  final String ru;
  final String en;

  String pick(bool russian) => russian ? ru : en;
}

/// A latitude/longitude pair, in degrees.
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;
}

/// ISO-3166 alpha-2 -> country name.
const Map<String, LocalizedName> geoCountries = <String, LocalizedName>{
  'DE': LocalizedName('Германия', 'Germany'),
  'NL': LocalizedName('Нидерланды', 'Netherlands'),
  'FR': LocalizedName('Франция', 'France'),
  'GB': LocalizedName('Великобритания', 'United Kingdom'),
  'IE': LocalizedName('Ирландия', 'Ireland'),
  'ES': LocalizedName('Испания', 'Spain'),
  'PT': LocalizedName('Португалия', 'Portugal'),
  'IT': LocalizedName('Италия', 'Italy'),
  'CH': LocalizedName('Швейцария', 'Switzerland'),
  'AT': LocalizedName('Австрия', 'Austria'),
  'BE': LocalizedName('Бельгия', 'Belgium'),
  'LU': LocalizedName('Люксембург', 'Luxembourg'),
  'CZ': LocalizedName('Чехия', 'Czechia'),
  'PL': LocalizedName('Польша', 'Poland'),
  'SK': LocalizedName('Словакия', 'Slovakia'),
  'SI': LocalizedName('Словения', 'Slovenia'),
  'HR': LocalizedName('Хорватия', 'Croatia'),
  'HU': LocalizedName('Венгрия', 'Hungary'),
  'RO': LocalizedName('Румыния', 'Romania'),
  'BG': LocalizedName('Болгария', 'Bulgaria'),
  'GR': LocalizedName('Греция', 'Greece'),
  'RS': LocalizedName('Сербия', 'Serbia'),
  'SE': LocalizedName('Швеция', 'Sweden'),
  'NO': LocalizedName('Норвегия', 'Norway'),
  'FI': LocalizedName('Финляндия', 'Finland'),
  'DK': LocalizedName('Дания', 'Denmark'),
  'IS': LocalizedName('Исландия', 'Iceland'),
  'EE': LocalizedName('Эстония', 'Estonia'),
  'LV': LocalizedName('Латвия', 'Latvia'),
  'LT': LocalizedName('Литва', 'Lithuania'),
  'MD': LocalizedName('Молдова', 'Moldova'),
  'UA': LocalizedName('Украина', 'Ukraine'),
  'BY': LocalizedName('Беларусь', 'Belarus'),
  'RU': LocalizedName('Россия', 'Russia'),
  'TR': LocalizedName('Турция', 'Turkey'),
  'CY': LocalizedName('Кипр', 'Cyprus'),
  'KZ': LocalizedName('Казахстан', 'Kazakhstan'),
  'KG': LocalizedName('Кыргызстан', 'Kyrgyzstan'),
  'UZ': LocalizedName('Узбекистан', 'Uzbekistan'),
  'TJ': LocalizedName('Таджикистан', 'Tajikistan'),
  'TM': LocalizedName('Туркменистан', 'Turkmenistan'),
  'AZ': LocalizedName('Азербайджан', 'Azerbaijan'),
  'GE': LocalizedName('Грузия', 'Georgia'),
  'AM': LocalizedName('Армения', 'Armenia'),
  'MN': LocalizedName('Монголия', 'Mongolia'),
  'IL': LocalizedName('Израиль', 'Israel'),
  'AE': LocalizedName('ОАЭ', 'United Arab Emirates'),
  'SA': LocalizedName('Саудовская Аравия', 'Saudi Arabia'),
  'QA': LocalizedName('Катар', 'Qatar'),
  'KW': LocalizedName('Кувейт', 'Kuwait'),
  'BH': LocalizedName('Бахрейн', 'Bahrain'),
  'OM': LocalizedName('Оман', 'Oman'),
  'JO': LocalizedName('Иордания', 'Jordan'),
  'IN': LocalizedName('Индия', 'India'),
  'PK': LocalizedName('Пакистан', 'Pakistan'),
  'BD': LocalizedName('Бангладеш', 'Bangladesh'),
  'LK': LocalizedName('Шри-Ланка', 'Sri Lanka'),
  'CN': LocalizedName('Китай', 'China'),
  'HK': LocalizedName('Гонконг', 'Hong Kong'),
  'TW': LocalizedName('Тайвань', 'Taiwan'),
  'JP': LocalizedName('Япония', 'Japan'),
  'KR': LocalizedName('Южная Корея', 'South Korea'),
  'SG': LocalizedName('Сингапур', 'Singapore'),
  'MY': LocalizedName('Малайзия', 'Malaysia'),
  'TH': LocalizedName('Таиланд', 'Thailand'),
  'VN': LocalizedName('Вьетнам', 'Vietnam'),
  'ID': LocalizedName('Индонезия', 'Indonesia'),
  'PH': LocalizedName('Филиппины', 'Philippines'),
  'AU': LocalizedName('Австралия', 'Australia'),
  'NZ': LocalizedName('Новая Зеландия', 'New Zealand'),
  'US': LocalizedName('США', 'United States'),
  'CA': LocalizedName('Канада', 'Canada'),
  'MX': LocalizedName('Мексика', 'Mexico'),
  'BR': LocalizedName('Бразилия', 'Brazil'),
  'AR': LocalizedName('Аргентина', 'Argentina'),
  'CL': LocalizedName('Чили', 'Chile'),
  'ZA': LocalizedName('ЮАР', 'South Africa'),
  'EG': LocalizedName('Египет', 'Egypt'),
  'NG': LocalizedName('Нигерия', 'Nigeria'),
  'KE': LocalizedName('Кения', 'Kenya'),
  'MA': LocalizedName('Марокко', 'Morocco'),
  'TN': LocalizedName('Тунис', 'Tunisia'),
};

/// City key -> city name. Keys are lower-case and free of spaces, hyphens and
/// punctuation; run a raw value through [cityKey] before looking it up.
const Map<String, LocalizedName> geoCities = <String, LocalizedName>{
  'frankfurt': LocalizedName('Франкфурт', 'Frankfurt'),
  'berlin': LocalizedName('Берлин', 'Berlin'),
  'munich': LocalizedName('Мюнхен', 'Munich'),
  'duesseldorf': LocalizedName('Дюссельдорф', 'Düsseldorf'),
  'amsterdam': LocalizedName('Амстердам', 'Amsterdam'),
  'paris': LocalizedName('Париж', 'Paris'),
  'london': LocalizedName('Лондон', 'London'),
  'dublin': LocalizedName('Дублин', 'Dublin'),
  'madrid': LocalizedName('Мадрид', 'Madrid'),
  'barcelona': LocalizedName('Барселона', 'Barcelona'),
  'lisbon': LocalizedName('Лиссабон', 'Lisbon'),
  'milan': LocalizedName('Милан', 'Milan'),
  'rome': LocalizedName('Рим', 'Rome'),
  'zurich': LocalizedName('Цюрих', 'Zurich'),
  'geneva': LocalizedName('Женева', 'Geneva'),
  'vienna': LocalizedName('Вена', 'Vienna'),
  'prague': LocalizedName('Прага', 'Prague'),
  'warsaw': LocalizedName('Варшава', 'Warsaw'),
  'stockholm': LocalizedName('Стокгольм', 'Stockholm'),
  'helsinki': LocalizedName('Хельсинки', 'Helsinki'),
  'oslo': LocalizedName('Осло', 'Oslo'),
  'copenhagen': LocalizedName('Копенгаген', 'Copenhagen'),
  'tallinn': LocalizedName('Таллин', 'Tallinn'),
  'riga': LocalizedName('Рига', 'Riga'),
  'vilnius': LocalizedName('Вильнюс', 'Vilnius'),
  'bucharest': LocalizedName('Бухарест', 'Bucharest'),
  'sofia': LocalizedName('София', 'Sofia'),
  'budapest': LocalizedName('Будапешт', 'Budapest'),
  'athens': LocalizedName('Афины', 'Athens'),
  'istanbul': LocalizedName('Истанбул', 'Istanbul'),
  'reykjavik': LocalizedName('Рейкьявик', 'Reykjavik'),
  'moscow': LocalizedName('Москва', 'Moscow'),
  'saintpetersburg': LocalizedName('Санкт-Петербург', 'Saint Petersburg'),
  'kyiv': LocalizedName('Киев', 'Kyiv'),
  'minsk': LocalizedName('Минск', 'Minsk'),
  'almaty': LocalizedName('Алматы', 'Almaty'),
  'astana': LocalizedName('Астана', 'Astana'),
  'shymkent': LocalizedName('Шымкент', 'Shymkent'),
  'aktobe': LocalizedName('Актобе', 'Aktobe'),
  'atyrau': LocalizedName('Атырау', 'Atyrau'),
  'karaganda': LocalizedName('Караганда', 'Karaganda'),
  'kyzylorda': LocalizedName('Кызылорда', 'Kyzylorda'),
  'bishkek': LocalizedName('Бишкек', 'Bishkek'),
  'tashkent': LocalizedName('Ташкент', 'Tashkent'),
  'samarkand': LocalizedName('Самарканд', 'Samarkand'),
  'dushanbe': LocalizedName('Душанбе', 'Dushanbe'),
  'ashgabat': LocalizedName('Ашхабад', 'Ashgabat'),
  'baku': LocalizedName('Баку', 'Baku'),
  'tbilisi': LocalizedName('Тбилиси', 'Tbilisi'),
  'yerevan': LocalizedName('Ереван', 'Yerevan'),
  'ulaanbaatar': LocalizedName('Улан-Батор', 'Ulaanbaatar'),
  'dubai': LocalizedName('Дубай', 'Dubai'),
  'telaviv': LocalizedName('Тель-Авив', 'Tel Aviv'),
  'singapore': LocalizedName('Сингапур', 'Singapore'),
  'tokyo': LocalizedName('Токио', 'Tokyo'),
  'seoul': LocalizedName('Сеул', 'Seoul'),
  'hongkong': LocalizedName('Гонконг', 'Hong Kong'),
  'taipei': LocalizedName('Тайбэй', 'Taipei'),
  'bangkok': LocalizedName('Бангкок', 'Bangkok'),
  'kualalumpur': LocalizedName('Куала-Лумпур', 'Kuala Lumpur'),
  'jakarta': LocalizedName('Джакарта', 'Jakarta'),
  'manila': LocalizedName('Манила', 'Manila'),
  'mumbai': LocalizedName('Мумбаи', 'Mumbai'),
  'delhi': LocalizedName('Дели', 'Delhi'),
  'karachi': LocalizedName('Карачи', 'Karachi'),
  'sydney': LocalizedName('Сидней', 'Sydney'),
  'melbourne': LocalizedName('Мельбурн', 'Melbourne'),
  'auckland': LocalizedName('Окленд', 'Auckland'),
  'toronto': LocalizedName('Торонто', 'Toronto'),
  'montreal': LocalizedName('Монреаль', 'Montreal'),
  'newyork': LocalizedName('Нью-Йорк', 'New York'),
  'chicago': LocalizedName('Чикаго', 'Chicago'),
  'dallas': LocalizedName('Даллас', 'Dallas'),
  'losangeles': LocalizedName('Лос-Анджелес', 'Los Angeles'),
  'seattle': LocalizedName('Сиэтл', 'Seattle'),
  'miami': LocalizedName('Майами', 'Miami'),
  'ashburn': LocalizedName('Ашберн', 'Ashburn'),
  'saopaulo': LocalizedName('Сан-Паулу', 'Sao Paulo'),
  'buenosaires': LocalizedName('Буэнос-Айрес', 'Buenos Aires'),
  'santiago': LocalizedName('Сантьяго', 'Santiago'),
  'mexicocity': LocalizedName('Мехико', 'Mexico City'),
  'johannesburg': LocalizedName('Йоханнесбург', 'Johannesburg'),
  'capetown': LocalizedName('Кейптаун', 'Cape Town'),
  'cairo': LocalizedName('Каир', 'Cairo'),
  'lagos': LocalizedName('Лагос', 'Lagos'),
  'nairobi': LocalizedName('Найроби', 'Nairobi'),
  'casablanca': LocalizedName('Касабланка', 'Casablanca'),
  'tunis': LocalizedName('Тунис', 'Tunis'),
};

/// City key -> where its dot goes on the map.
const Map<String, GeoPoint> cityCoords = <String, GeoPoint>{
  'frankfurt': GeoPoint(50.11, 8.68),
  'berlin': GeoPoint(52.52, 13.40),
  'munich': GeoPoint(48.14, 11.58),
  'duesseldorf': GeoPoint(51.23, 6.78),
  'amsterdam': GeoPoint(52.37, 4.90),
  'paris': GeoPoint(48.86, 2.35),
  'london': GeoPoint(51.51, -0.13),
  'dublin': GeoPoint(53.35, -6.26),
  'madrid': GeoPoint(40.42, -3.70),
  'barcelona': GeoPoint(41.39, 2.17),
  'lisbon': GeoPoint(38.72, -9.14),
  'milan': GeoPoint(45.46, 9.19),
  'rome': GeoPoint(41.90, 12.50),
  'zurich': GeoPoint(47.38, 8.54),
  'geneva': GeoPoint(46.20, 6.14),
  'vienna': GeoPoint(48.21, 16.37),
  'prague': GeoPoint(50.08, 14.44),
  'warsaw': GeoPoint(52.23, 21.01),
  'stockholm': GeoPoint(59.33, 18.07),
  'helsinki': GeoPoint(60.17, 24.94),
  'oslo': GeoPoint(59.91, 10.75),
  'copenhagen': GeoPoint(55.68, 12.57),
  'tallinn': GeoPoint(59.44, 24.75),
  'riga': GeoPoint(56.95, 24.11),
  'vilnius': GeoPoint(54.69, 25.28),
  'bucharest': GeoPoint(44.43, 26.10),
  'sofia': GeoPoint(42.70, 23.32),
  'budapest': GeoPoint(47.50, 19.04),
  'athens': GeoPoint(37.98, 23.73),
  'istanbul': GeoPoint(41.01, 28.98),
  'reykjavik': GeoPoint(64.15, -21.94),
  'moscow': GeoPoint(55.75, 37.62),
  'saintpetersburg': GeoPoint(59.94, 30.31),
  'kyiv': GeoPoint(50.45, 30.52),
  'minsk': GeoPoint(53.90, 27.57),
  'almaty': GeoPoint(43.24, 76.89),
  'astana': GeoPoint(51.13, 71.43),
  'shymkent': GeoPoint(42.32, 69.60),
  'aktobe': GeoPoint(50.28, 57.17),
  'atyrau': GeoPoint(47.09, 51.92),
  'karaganda': GeoPoint(49.81, 73.09),
  'kyzylorda': GeoPoint(44.85, 65.51),
  'bishkek': GeoPoint(42.87, 74.59),
  'tashkent': GeoPoint(41.30, 69.24),
  'samarkand': GeoPoint(39.65, 66.96),
  'dushanbe': GeoPoint(38.56, 68.79),
  'ashgabat': GeoPoint(37.95, 58.38),
  'baku': GeoPoint(40.41, 49.87),
  'tbilisi': GeoPoint(41.72, 44.79),
  'yerevan': GeoPoint(40.18, 44.51),
  'ulaanbaatar': GeoPoint(47.89, 106.91),
  'dubai': GeoPoint(25.20, 55.27),
  'telaviv': GeoPoint(32.09, 34.78),
  'singapore': GeoPoint(1.35, 103.82),
  'tokyo': GeoPoint(35.68, 139.69),
  'seoul': GeoPoint(37.57, 126.98),
  'hongkong': GeoPoint(22.32, 114.17),
  'taipei': GeoPoint(25.03, 121.57),
  'bangkok': GeoPoint(13.76, 100.50),
  'kualalumpur': GeoPoint(3.14, 101.69),
  'jakarta': GeoPoint(-6.21, 106.85),
  'manila': GeoPoint(14.60, 120.98),
  'mumbai': GeoPoint(19.08, 72.88),
  'delhi': GeoPoint(28.61, 77.21),
  'karachi': GeoPoint(24.86, 67.01),
  'sydney': GeoPoint(-33.87, 151.21),
  'melbourne': GeoPoint(-37.81, 144.96),
  'auckland': GeoPoint(-36.85, 174.76),
  'toronto': GeoPoint(43.65, -79.38),
  'montreal': GeoPoint(45.50, -73.57),
  'newyork': GeoPoint(40.71, -74.01),
  'chicago': GeoPoint(41.88, -87.63),
  'dallas': GeoPoint(32.78, -96.80),
  'losangeles': GeoPoint(34.05, -118.24),
  'seattle': GeoPoint(47.61, -122.33),
  'miami': GeoPoint(25.76, -80.19),
  'ashburn': GeoPoint(39.04, -77.49),
  'saopaulo': GeoPoint(-23.55, -46.63),
  'buenosaires': GeoPoint(-34.60, -58.38),
  'santiago': GeoPoint(-33.45, -70.67),
  'mexicocity': GeoPoint(19.43, -99.13),
  'johannesburg': GeoPoint(-26.20, 28.05),
  'capetown': GeoPoint(-33.92, 18.42),
  'cairo': GeoPoint(30.04, 31.24),
  'lagos': GeoPoint(6.52, 3.38),
  'nairobi': GeoPoint(-1.29, 36.82),
  'casablanca': GeoPoint(33.57, -7.59),
  'tunis': GeoPoint(36.81, 10.18),
};

/// Normalises a raw city string into a [geoCities] key.
///
/// The control plane is not consistent: "Frankfurt", "frankfurt am main",
/// "Saint-Petersburg" and "SAINT PETERSBURG" all arrive at different times.
String? cityKey(String? raw) {
  if (raw == null) return null;
  final String key = raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-zа-яё0-9]'), '')
      .trim();
  if (key.isEmpty) return null;
  if (geoCities.containsKey(key)) return key;

  // "frankfurtammain" -> "frankfurt", "newyorkcity" -> "newyork".
  for (final String candidate in geoCities.keys) {
    if (key.startsWith(candidate)) return candidate;
  }
  return key;
}

/// Country name in the interface language, falling back to the raw code.
String localizeCountry(
  String? code, {
  bool russian = true,
  String? fallback,
}) {
  final String normalised = (code ?? '').trim().toUpperCase();
  final LocalizedName? name = geoCountries[normalised];
  if (name != null) return name.pick(russian);
  if (fallback != null && fallback.trim().isNotEmpty) return fallback.trim();
  return normalised;
}

/// City name in the interface language, falling back to a tidied raw value.
String localizeCity(String? city, {bool russian = true}) {
  final String? key = cityKey(city);
  final LocalizedName? name = key == null ? null : geoCities[key];
  if (name != null) return name.pick(russian);

  final String raw = (city ?? '').trim();
  if (raw.isEmpty) return '';
  // Title-case whatever we were given so "frankfurt" never reaches the UI.
  return raw
      .split(RegExp(r'[\s_-]+'))
      .where((String part) => part.isNotEmpty)
      .map((String part) =>
          part[0].toUpperCase() + part.substring(1).toLowerCase())
      .join(' ');
}

/// Coordinates for a city, when we know it.
GeoPoint? cityPoint(String? city) {
  final String? key = cityKey(city);
  return key == null ? null : cityCoords[key];
}

/// "Франкфурт, Германия" / "Frankfurt, Germany".
///
/// This is the label shape the user asked for: city first, country second, both
/// translated. Matches `formatNodeLocation` in `extension/lib/geo.js`.
String formatNodeLocation({
  String? city,
  String? countryCode,
  String? countryName,
  String? region,
  bool russian = true,
}) {
  final String cityText = localizeCity(city, russian: russian);
  final String countryText = localizeCountry(
    countryCode,
    russian: russian,
    fallback: countryName,
  );

  if (cityText.isNotEmpty && countryText.isNotEmpty) {
    return '$cityText, $countryText';
  }
  if (cityText.isNotEmpty) return cityText;
  if (countryText.isNotEmpty) return countryText;

  final String regionText = (region ?? '').trim();
  return regionText;
}

/// Same as [formatNodeLocation] but for the user's own position, where the city
/// is usually unknown and the country carries the label.
String formatSelfLocation({
  String? city,
  String? countryCode,
  String? countryName,
  String? region,
  bool russian = true,
}) {
  final String cityText = localizeCity(city, russian: russian);
  final String countryText = localizeCountry(
    countryCode,
    russian: russian,
    fallback: countryName,
  );
  if (cityText.isNotEmpty && countryText.isNotEmpty) {
    return '$cityText, $countryText';
  }
  if (countryText.isNotEmpty) return countryText;
  final String regionText = (region ?? '').trim();
  if (regionText.isNotEmpty) return regionText;
  return russian ? 'Не определено' : 'Unknown';
}
