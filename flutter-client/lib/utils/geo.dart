import 'dart:io' show Platform;
import 'dart:math' as math;

import 'geo_dictionary.dart';

/// Coordinate maths for the dotted world map.
///
/// The map asset is an equirectangular projection with `viewBox="0 0 119 60"`,
/// so a latitude/longitude pair maps to map space with:
///
///   x = (lon + 180) / 360 * 119
///   y = (90 - lat) / 180 * 60
///
/// Verified against the two points hard-coded in the mockup: Frankfurt
/// (8.68E, 50.11N) -> 62.37 / 13.30, and Kokshetau (69.39E, 53.28N) ->
/// 82.44 / 12.24. Both match to two decimals.
class MapPoint {
	const MapPoint(this.x, this.y);

	/// 0..119 in map space.
	final double x;

	/// 0..60 in map space.
	final double y;

	/// Fraction of the map's width, for laying out over a scaled image.
	double get fx => x / mapWidth;

	/// Fraction of the map's height.
	double get fy => y / mapHeight;

	@override
	String toString() => 'MapPoint(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})';
}

/// The map asset's viewBox.
const double mapWidth = 119;
const double mapHeight = 60;

/// Project geographic coordinates into map space.
MapPoint projectLatLon(double lat, double lon) {
	final clampedLat = lat.clamp(-90.0, 90.0).toDouble();
	final clampedLon = lon.clamp(-180.0, 180.0).toDouble();
	return MapPoint(
		(clampedLon + 180) / 360 * mapWidth,
		(90 - clampedLat) / 180 * mapHeight,
	);
}

/// Approximate centres for the countries we can plot: VPN node locations plus
/// the countries our test devices are likely to sit in.
///
/// These are coarse on purpose. The map dot means "roughly this country", never
/// "this address" - the app asks for no location permission and contacts no
/// geolocation service.
const Map<String, ({double lat, double lon, String name, String flag})> countryCentres = {
	'DE': (lat: 50.11, lon: 8.68, name: 'Germany', flag: '\u{1F1E9}\u{1F1EA}'),
	'NL': (lat: 52.37, lon: 4.90, name: 'Netherlands', flag: '\u{1F1F3}\u{1F1F1}'),
	'FR': (lat: 48.86, lon: 2.35, name: 'France', flag: '\u{1F1EB}\u{1F1F7}'),
	'GB': (lat: 51.51, lon: -0.13, name: 'United Kingdom', flag: '\u{1F1EC}\u{1F1E7}'),
	'FI': (lat: 60.17, lon: 24.94, name: 'Finland', flag: '\u{1F1EB}\u{1F1EE}'),
	'SE': (lat: 59.33, lon: 18.07, name: 'Sweden', flag: '\u{1F1F8}\u{1F1EA}'),
	'PL': (lat: 52.23, lon: 21.01, name: 'Poland', flag: '\u{1F1F5}\u{1F1F1}'),
	'CH': (lat: 47.37, lon: 8.54, name: 'Switzerland', flag: '\u{1F1E8}\u{1F1ED}'),
	'AT': (lat: 48.21, lon: 16.37, name: 'Austria', flag: '\u{1F1E6}\u{1F1F9}'),
	'ES': (lat: 40.42, lon: -3.70, name: 'Spain', flag: '\u{1F1EA}\u{1F1F8}'),
	'IT': (lat: 41.90, lon: 12.50, name: 'Italy', flag: '\u{1F1EE}\u{1F1F9}'),
	'TR': (lat: 39.93, lon: 32.86, name: 'Turkey', flag: '\u{1F1F9}\u{1F1F7}'),
	'US': (lat: 38.90, lon: -77.04, name: 'United States', flag: '\u{1F1FA}\u{1F1F8}'),
	'CA': (lat: 45.42, lon: -75.70, name: 'Canada', flag: '\u{1F1E8}\u{1F1E6}'),
	'BR': (lat: -15.79, lon: -47.88, name: 'Brazil', flag: '\u{1F1E7}\u{1F1F7}'),
	'AR': (lat: -34.60, lon: -58.38, name: 'Argentina', flag: '\u{1F1E6}\u{1F1F7}'),
	'KZ': (lat: 51.13, lon: 71.43, name: 'Kazakhstan', flag: '\u{1F1F0}\u{1F1FF}'),
	'RU': (lat: 55.75, lon: 37.62, name: 'Russia', flag: '\u{1F1F7}\u{1F1FA}'),
	'UA': (lat: 50.45, lon: 30.52, name: 'Ukraine', flag: '\u{1F1FA}\u{1F1E6}'),
	'UZ': (lat: 41.31, lon: 69.24, name: 'Uzbekistan', flag: '\u{1F1FA}\u{1F1FF}'),
	'KG': (lat: 42.87, lon: 74.59, name: 'Kyrgyzstan', flag: '\u{1F1F0}\u{1F1EC}'),
	'GE': (lat: 41.72, lon: 44.78, name: 'Georgia', flag: '\u{1F1EC}\u{1F1EA}'),
	'AE': (lat: 25.20, lon: 55.27, name: 'United Arab Emirates', flag: '\u{1F1E6}\u{1F1EA}'),
	'IN': (lat: 28.61, lon: 77.21, name: 'India', flag: '\u{1F1EE}\u{1F1F3}'),
	'SG': (lat: 1.35, lon: 103.82, name: 'Singapore', flag: '\u{1F1F8}\u{1F1EC}'),
	'JP': (lat: 35.68, lon: 139.69, name: 'Japan', flag: '\u{1F1EF}\u{1F1F5}'),
	'KR': (lat: 37.57, lon: 126.98, name: 'South Korea', flag: '\u{1F1F0}\u{1F1F7}'),
	'AU': (lat: -35.28, lon: 149.13, name: 'Australia', flag: '\u{1F1E6}\u{1F1FA}'),
	'ZA': (lat: -25.75, lon: 28.19, name: 'South Africa', flag: '\u{1F1FF}\u{1F1E6}'),
};

/// Where a country should be drawn, or null if we have no entry for it.
MapPoint? countryPoint(String? countryCode) {
	if (countryCode == null || countryCode.isEmpty) return null;
	final centre = countryCentres[countryCode.toUpperCase()];
	if (centre == null) return null;
	return projectLatLon(centre.lat, centre.lon);
}

/// Flag emoji for a country code, derived from the code itself when we have no
/// entry - every ISO-3166 alpha-2 code maps to a regional-indicator pair.
String countryFlag(String? countryCode) {
	final code = countryCode?.toUpperCase();
	if (code == null || code.length != 2) return '\u{1F310}'; // globe
	final known = countryCentres[code];
	if (known != null) return known.flag;
	final first = code.codeUnitAt(0);
	final second = code.codeUnitAt(1);
	const a = 65; // 'A'
	const z = 90; // 'Z'
	if (first < a || first > z || second < a || second > z) return '\u{1F310}';
	return String.fromCharCodes([0x1F1E6 + (first - a), 0x1F1E6 + (second - a)]);
}

/// The user's approximate position for the "you" dot on the map.
///
/// Resolved best evidence first:
///   1. the country the control plane resolved from the request's IP. That is
///      the network's own view of where the device is, and the only source that
///      can tell a Russian-language phone in Moscow from the same phone in
///      Kazakhstan;
///   2. the device's UTC offset, which pins a longitude to within a timezone's
///      width, matched to the nearest country we can plot;
///   3. the locale's region (`ru_KZ` -> KZ) - but only when it agrees with that
///      longitude.
///
/// The locale used to come first, and that is precisely the bug it caused:
/// `ru_RU` on a phone in Astana parked the marker on Moscow. Language is not
/// location. The clock is weak evidence but it is *about* where you are, so it
/// now outranks the keyboard.
///
/// Still no GPS and no location permission at any step, and the finest
/// resolution anywhere in this file is a country centre.
class SelfLocation {
	const SelfLocation({
		required this.point,
		required this.precision,
		this.countryCode,
		this.countryName,
		this.region,
	});

	final MapPoint point;
	final String? countryCode;
	final String? countryName;

	/// City or region, when the control plane reported one.
	final String? region;

	/// 'network' when the control plane resolved the IP, 'country' when the
	/// locale's region was used, 'timezone' when only the UTC offset was.
	final String precision;

	/// True when this came from the network rather than a guess on the device.
	bool get fromNetwork => precision == 'network';

	String get label => countryName ?? 'Your location';

	/// Localised "Кызылорда, Казахстан" / "Kyzylorda, Kazakhstan".
	///
	/// Goes through the shared dictionary, so a country reads the same in the
	/// desktop app, the phone app and the extension instead of showing a bare
	/// "KG" on one of them.
	String localizedPlace({bool russian = true}) => formatSelfLocation(
			city: region,
			countryCode: countryCode,
			countryName: countryName,
			russian: russian,
		);

	/// "Frankfurt, Germany" when both halves are known. Kept for callers with no
	/// language context; prefer [localizedPlace].
	String get placeLabel {
		final String? city = region;
		final String? country = countryName;
		if (city != null && city.isNotEmpty && country != null) {
			return '$city, $country';
		}
		return label;
	}

	String get flag => countryFlag(countryCode);
}

/// Shortest angular distance between two longitudes, in degrees.
double longitudeGap(double a, double b) {
	final double delta = ((a - b + 540) % 360) - 180;
	return delta.abs();
}

/// How far a locale's region may sit from the longitude the clock implies
/// before we stop believing it. A little over one and a half timezones: wide
/// enough for a large country, narrow enough to reject a neighbour.
const double localeAgreementDegrees = 25;

/// Curated timezone -> most likely country, keyed by UTC offset in minutes.
///
/// ROUND 5: the app placed the user in Kyrgyzstan while they were in
/// Kazakhstan, and pure geometry is why. At UTC+5 the implied meridian is 75E,
/// and the nearest country centre to it is Kyrgyzstan at 74.8E. Kazakhstan sits
/// at 68E and lost by seven degrees, despite being the far more likely answer
/// on that meridian. Longitude cannot break a tie like this; a curated list
/// can. First entry wins, unless the locale's own region appears in the list.
const Map<int, List<String>> utcOffsetCountries = <int, List<String>>{
	-480: <String>['US', 'CA'],
	-420: <String>['US', 'CA', 'MX'],
	-360: <String>['US', 'MX', 'CA'],
	-300: <String>['US', 'CA', 'BR'],
	-240: <String>['CL', 'CA', 'BR'],
	-180: <String>['BR', 'AR'],
	0: <String>['GB', 'IE', 'PT', 'IS', 'MA'],
	60: <String>[
		'DE', 'FR', 'NL', 'ES', 'IT', 'PL', 'SE', 'CH',
		'AT', 'CZ', 'BE', 'DK', 'NO', 'HU', 'RS', 'HR',
	],
	120: <String>['FI', 'GR', 'RO', 'BG', 'UA', 'EE', 'LV', 'LT', 'IL', 'EG', 'ZA'],
	180: <String>['RU', 'TR', 'BY', 'SA', 'KE'],
	240: <String>['AE', 'AZ', 'GE', 'AM', 'OM'],
	300: <String>['KZ', 'UZ', 'PK', 'TM', 'TJ', 'KG'],
	330: <String>['IN', 'LK'],
	360: <String>['KZ', 'KG', 'BD'],
	420: <String>['TH', 'VN', 'ID', 'MN'],
	480: <String>['CN', 'SG', 'HK', 'MY', 'TW', 'PH'],
	540: <String>['JP', 'KR'],
	600: <String>['AU'],
	720: <String>['NZ'],
};

/// The country in [countryCentres] that best fits a UTC offset.
///
/// [utcOffsetCountries] decides first. Only for an offset missing from that
/// table do we fall back to geometry: 15 degrees of longitude per hour, then
/// the nearest centre by longitude with a mild preference for the northern
/// mid-latitudes, where the devices are.
/// Null when nothing is close enough to be worth claiming.
String? countryForUtcOffset(Duration offset, {String? preferRegion}) {
	final List<String>? curated = utcOffsetCountries[offset.inMinutes];
	if (curated != null && curated.isNotEmpty) {
		// A locale region that sits inside the same timezone is better evidence
		// than a popularity ranking: ru_KZ at UTC+5 really is Kazakhstan.
		final String? region = preferRegion?.toUpperCase();
		if (region != null && curated.contains(region)) return region;
		for (final String code in curated) {
			if (countryCentres.containsKey(code)) return code;
		}
	}

	final double longitude = (offset.inMinutes / 60.0) * 15.0;
	String? best;
	double bestScore = double.infinity;
	for (final String code in countryCentres.keys) {
		final centre = countryCentres[code]!;
		final double gap = longitudeGap(centre.lon, longitude);
		if (gap > 30) continue;
		final double score = gap + 0.25 * (centre.lat - 45).abs();
		if (score < bestScore) {
			bestScore = score;
			best = code;
		}
	}
	return best;
}

SelfLocation approximateSelfLocation({
	String? originCountryCode,
	String? originCountryName,
	String? originRegion,
	String? localeOverride,
	Duration? utcOffsetOverride,
}) {
	// 1. What the control plane saw.
	final String? origin = originCountryCode?.toUpperCase();
	if (origin != null && origin.length == 2) {
		final centre = countryCentres[origin];
		if (centre != null) {
			return SelfLocation(
				point: projectLatLon(centre.lat, centre.lon),
				precision: 'network',
				countryCode: origin,
				countryName: originCountryName ?? centre.name,
				region: originRegion,
			);
		}
	}

	final Duration offset = utcOffsetOverride ?? DateTime.now().timeZoneOffset;
	final double tzLongitude = (offset.inMinutes / 60.0) * 15.0;

	// 2. The locale's region, when the clock does not contradict it.
	final String locale = localeOverride ?? _platformLocale();
	final String? region = _regionFromLocale(locale);
	final centre = region == null ? null : countryCentres[region];
	if (centre != null &&
			longitudeGap(centre.lon, tzLongitude) <= localeAgreementDegrees) {
		return SelfLocation(
			point: projectLatLon(centre.lat, centre.lon),
			precision: 'country',
			countryCode: region,
			countryName: centre.name,
		);
	}

	// 3. Nearest country for this timezone.
	final String? nearest = countryForUtcOffset(offset, preferRegion: region);
	final nearestCentre = nearest == null ? null : countryCentres[nearest];
	if (nearestCentre != null) {
		return SelfLocation(
			point: projectLatLon(nearestCentre.lat, nearestCentre.lon),
			precision: 'timezone',
			countryCode: nearest,
			countryName: nearestCentre.name,
		);
	}

	// Nothing plottable: put the marker on the meridian the clock implies.
	return SelfLocation(
		point: projectLatLon(45, tzLongitude.clamp(-180.0, 180.0)),
		precision: 'timezone',
		countryCode: region,
		countryName: null,
	);
}

String _platformLocale() {
	try {
		return Platform.localeName; // e.g. "ru_KZ.UTF-8"
	} catch (_) {
		return '';
	}
}

/// Pull the region out of forms like `ru_KZ`, `ru-KZ.UTF-8`, `en_US`.
String? _regionFromLocale(String locale) {
	if (locale.isEmpty) return null;
	final cleaned = locale.split('.').first.replaceAll('-', '_');
	final parts = cleaned.split('_');
	for (final part in parts.skip(1)) {
		if (part.length == 2 && part == part.toUpperCase()) return part;
	}
	return null;
}

/// The quadratic arc the mockup draws between two points:
/// `M you Q midX,midY server`, where the control point is lifted 9 map units
/// above the higher of the two, giving the cable its bow.
class ConnectionArc {
	const ConnectionArc({required this.from, required this.to});

	final MapPoint from;
	final MapPoint to;

	MapPoint get control => MapPoint(
		(from.x + to.x) / 2,
		math.min(from.y, to.y) - 9,
	);

	/// Sample the curve, for painters that need points rather than a path.
	MapPoint pointAt(double t) {
		final c = control;
		final inv = 1 - t;
		return MapPoint(
			inv * inv * from.x + 2 * inv * t * c.x + t * t * to.x,
			inv * inv * from.y + 2 * inv * t * c.y + t * t * to.y,
		);
	}
}
