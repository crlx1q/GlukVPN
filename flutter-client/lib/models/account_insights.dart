library;

import 'models.dart';

Map<String, dynamic> _map(Object? value) => value is Map
    ? value.map((Object? k, Object? v) => MapEntry<String, dynamic>('$k', v))
    : const <String, dynamic>{};
int _int(Object? value) => value is num && value.isFinite ? value.toInt() : int.tryParse('$value') ?? 0;
double? _double(Object? value) { final parsed = value is num ? value.toDouble() : double.tryParse('$value'); return parsed != null && parsed.isFinite ? parsed : null; }
// Процент тренда: сервер уже округлил его до целого, но `null` здесь
// значимое значение — «сравнивать не с чем», а не «ноль процентов».
int? _percent(Object? value) { final double? parsed = _double(value); return parsed == null ? null : parsed.round(); }
DateTime? _date(Object? value) => value is String ? DateTime.tryParse(value)?.toLocal() : null;

class ServiceStatus {
  const ServiceStatus({required this.registrationEnabled, required this.maintenance, this.retryAfterSec = 30});
  factory ServiceStatus.fromJson(Map<String, dynamic> json) => ServiceStatus(
    registrationEnabled: json['registrationEnabled'] != false,
    maintenance: json['maintenance'] == true,
    retryAfterSec: (json['retryAfterSec'] == null ? 30 : _int(json['retryAfterSec'])).clamp(1, 3600).toInt(),
  );
  static const available = ServiceStatus(registrationEnabled: true, maintenance: false);
  final bool registrationEnabled;
  final bool maintenance;
  final int retryAfterSec;
}

class GeoPoint {
  const GeoPoint(this.lat, this.lon, {required this.approximate, required this.source, this.country, this.countryCode});
  factory GeoPoint.fromJson(Map<String, dynamic> json) => GeoPoint(
    _double(json['lat']) ?? double.nan, _double(json['lon']) ?? double.nan,
    approximate: json['approximate'] != false,
    source: '${json['source'] ?? ''}', country: json['country'] as String?, countryCode: json['countryCode'] as String?,
  );
  final double lat;
  final double lon;
  final bool approximate;
  final String source;
  final String? country;
  final String? countryCode;
  bool get valid => lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180;
}

class ActiveTunnelDevice {
  const ActiveTunnelDevice({required this.id, required this.deviceName, required this.platform, required this.lastSeen, required this.isCurrent, required this.connectedAt, required this.durationSec, required this.node, this.origin, this.status = 'ACTIVE', this.sessionId});
  factory ActiveTunnelDevice.fromJson(Map<String, dynamic> json) {
    final originJson = _map(json['origin']);
    return ActiveTunnelDevice(
      status: '${json['status'] ?? 'ACTIVE'}', id: '${json['id'] ?? ''}', deviceName: '${json['deviceName'] ?? 'Device'}', platform: '${json['platform'] ?? ''}',
      // Сессия нужна кнопке «Отключить»: она гасит именно туннель,
      // а не выкидывает устройство из аккаунта.
      sessionId: '${json['sessionId'] ?? ''}'.isEmpty ? null : '${json['sessionId']}',
      lastSeen: _date(json['lastSeen']), isCurrent: json['isCurrent'] == true, connectedAt: _date(json['connectedAt']),
      durationSec: _int(json['durationSec']), node: VpnNodeInfo.fromJson(_map(json['node'])),
      origin: originJson.isEmpty ? null : GeoPoint.fromJson(originJson),
    );
  }
  final String id;
  final String? sessionId;
  final String deviceName;
  final String status;
  final String platform;
  final DateTime? lastSeen;
  final bool isCurrent;
  final DateTime? connectedAt;
  final int durationSec;
  final GeoPoint? origin;
  final VpnNodeInfo node;
}

class ActiveMapSnapshot {
  const ActiveMapSnapshot({required this.serverTime, required this.pollAfterMs, required this.activeTunnels, required this.maxDevices, required this.truncated, required this.service, required this.devices});
  factory ActiveMapSnapshot.fromJson(Map<String, dynamic> json) {
    final raw = json['devices'];
    return ActiveMapSnapshot(
      serverTime: _date(json['serverTime']), pollAfterMs: _int(json['pollAfterMs']).clamp(3000, 60000).toInt(),
      activeTunnels: _int(json['activeTunnels']), maxDevices: _int(json['maxDevices']), truncated: json['truncated'] == true,
      service: ServiceStatus.fromJson(_map(json['service'])),
      devices: raw is List ? raw.map((e) => ActiveTunnelDevice.fromJson(_map(e))).toList(growable: false) : const <ActiveTunnelDevice>[],
    );
  }
  final DateTime? serverTime;
  final int pollAfterMs;
  final int activeTunnels;
  final int maxDevices;
  final bool truncated;
  final ServiceStatus service;
  final List<ActiveTunnelDevice> devices;
}

enum AnalyticsPeriod { day, week, month }
extension AnalyticsPeriodWire on AnalyticsPeriod { String get wire => name; }

class TrafficPoint {
  const TrafficPoint({required this.start, required this.downloadBytes, required this.uploadBytes});
  factory TrafficPoint.fromJson(Map<String, dynamic> json) => TrafficPoint(start: _date(json['start']), downloadBytes: _int(json['downloadBytes']), uploadBytes: _int(json['uploadBytes']));
  final DateTime? start;
  final int downloadBytes;
  final int uploadBytes;
  int get totalBytes => downloadBytes + uploadBytes;
}

class AnalyticsDevice {
  const AnalyticsDevice({required this.deviceId, required this.deviceName, required this.platform, required this.downloadBytes, required this.uploadBytes});
  factory AnalyticsDevice.fromJson(Map<String, dynamic> json) => AnalyticsDevice(deviceId: '${json['deviceId'] ?? ''}', deviceName: '${json['deviceName'] ?? 'Device'}', platform: '${json['platform'] ?? ''}', downloadBytes: _int(json['downloadBytes']), uploadBytes: _int(json['uploadBytes']));
  final String deviceId, deviceName, platform;
  final int downloadBytes, uploadBytes;
  int get totalBytes => downloadBytes + uploadBytes;
}

class DomainUsage {
  const DomainUsage({required this.domain, required this.category, required this.downloadBytes, required this.uploadBytes, required this.connections, this.lastSeenAt, this.faviconUrl});
  factory DomainUsage.fromJson(Map<String, dynamic> json) => DomainUsage(domain: '${json['domain'] ?? ''}', category: '${json['category'] ?? ''}', downloadBytes: _int(json['downloadBytes']), uploadBytes: _int(json['uploadBytes']), connections: _int(json['connections']), lastSeenAt: _date(json['lastSeenAt']), faviconUrl: json['faviconUrl'] as String?);
  final String domain, category;
  final int downloadBytes, uploadBytes, connections;
  final DateTime? lastSeenAt;
  final String? faviconUrl;
  int get totalBytes => downloadBytes + uploadBytes;
}

class CategoryUsage {
  const CategoryUsage({required this.category, required this.downloadBytes, required this.uploadBytes});
  factory CategoryUsage.fromJson(Map<String, dynamic> json) => CategoryUsage(category: '${json['category'] ?? ''}', downloadBytes: _int(json['downloadBytes']), uploadBytes: _int(json['uploadBytes']));
  final String category;
  final int downloadBytes, uploadBytes;
  int get totalBytes => downloadBytes + uploadBytes;
}

class ServiceBudget {
  const ServiceBudget({required this.available, required this.usedBytes, required this.budgetBytes, required this.usedPercent, this.cycleStart, this.cycleEnd, this.lastPolledAt, this.adminOnly = false});
  factory ServiceBudget.fromJson(Map<String, dynamic> json) => ServiceBudget(adminOnly: json['adminOnly'] == true, available: json['available'] == true, usedBytes: _int(json['usedBytes']), budgetBytes: _int(json['budgetBytes']), usedPercent: _double(json['usedPercent']) ?? 0, cycleStart: _date(json['cycleStart']), cycleEnd: _date(json['cycleEnd']), lastPolledAt: _date(json['lastPolledAt']));
  final bool available;
  final bool adminOnly;
  final int usedBytes, budgetBytes;
  final double usedPercent;
  final DateTime? cycleStart, cycleEnd, lastPolledAt;
}

/// Прошлое окно той же длины — основа тренда «+12 %».
///
/// Сервер обрезает его по прошедшей части текущего периода: «сегодня с
/// утра» сравнивается со «вчера до этого же часа». Иначе утро всегда
/// показывало бы падение относительно полных вчерашних суток.
class PreviousWindow {
  const PreviousWindow({required this.start, required this.end, required this.downloadBytes, required this.uploadBytes});
  factory PreviousWindow.fromJson(Map<String, dynamic> json) => PreviousWindow(
    start: _date(json['start']), end: _date(json['end']),
    downloadBytes: _int(json['downloadBytes']), uploadBytes: _int(json['uploadBytes']),
  );
  final DateTime? start, end;
  final int downloadBytes, uploadBytes;
  int get totalBytes => downloadBytes + uploadBytes;
}

/// Тренд период-к-периоду в целых процентах.
///
/// `comparable == false` означает «сравнивать не с чем»: история короче
/// прошлого окна. Рисовать тогда «+100 %» нельзя — это была бы не
/// разница трафика, а дата включения аналитики.
class TrendInfo {
  const TrendInfo({required this.comparable, this.downloadPercent, this.uploadPercent, this.totalPercent});
  factory TrendInfo.fromJson(Map<String, dynamic> json) => TrendInfo(
    comparable: json['comparable'] == true,
    downloadPercent: _percent(json['downloadPercent']),
    uploadPercent: _percent(json['uploadPercent']),
    totalPercent: _percent(json['totalPercent']),
  );

  /// Старый ответ API: полей нет, бейджи не рисуем.
  static const TrendInfo none = TrendInfo(comparable: false);

  final bool comparable;
  final int? downloadPercent, uploadPercent, totalPercent;

  /// Значения для показа: `null` — бейджа нет вовсе.
  int? get download => comparable ? downloadPercent : null;
  int? get upload => comparable ? uploadPercent : null;
  int? get total => comparable ? totalPercent : null;
}

class AnalyticsSnapshot {
  const AnalyticsSnapshot({required this.period, required this.partial, required this.coverageSince, required this.downloadBytes, required this.uploadBytes, required this.series, required this.devices, required this.domainsEnabled, required this.domainWindowDays, required this.domains, required this.categories, required this.budget, this.quota, this.previous, this.trend = TrendInfo.none});
  factory AnalyticsSnapshot.fromJson(Map<String, dynamic> json) {
    final coverage = _map(json['coverage']); final totals = _map(json['totals']); final domains = _map(json['domains']);
    List<T> list<T>(Object? raw, T Function(Map<String,dynamic>) parse) => raw is List ? raw.map((e) => parse(_map(e))).toList(growable:false) : <T>[];
    return AnalyticsSnapshot(
      period: '${json['period'] ?? 'day'}', partial: coverage['partial'] == true, coverageSince: _date(coverage['since']),
      downloadBytes: _int(totals['downloadBytes']), uploadBytes: _int(totals['uploadBytes']),
      series: list(json['series'], TrafficPoint.fromJson), devices: list(json['devices'], AnalyticsDevice.fromJson),
      domainsEnabled: domains['enabled'] == true, domainWindowDays: _int(domains['windowDays']), domains: list(domains['items'], DomainUsage.fromJson),
      categories: list(json['categories'], CategoryUsage.fromJson), budget: ServiceBudget.fromJson(_map(json['budget'])),
      // Личный лимит тарифа — не путать с `budget` выше: тот сервисный
      // и виден только админам.
      quota: json['quota'] == null ? null : QuotaInfo.fromJson(_map(json['quota'])),
      // Старые ответы без previous/trend обязаны разбираться как раньше:
      // клиент обновляется не одновременно с сервером.
      previous: json['previous'] == null ? null : PreviousWindow.fromJson(_map(json['previous'])),
      trend: json['trend'] == null ? TrendInfo.none : TrendInfo.fromJson(_map(json['trend'])),
    );
  }
  final String period;
  final bool partial;
  final DateTime? coverageSince;
  final int downloadBytes, uploadBytes;
  final List<TrafficPoint> series;
  final List<AnalyticsDevice> devices;
  final bool domainsEnabled;
  final int domainWindowDays;
  final List<DomainUsage> domains;
  final List<CategoryUsage> categories;
  final ServiceBudget budget;

  /// Месячный лимит тарифа по данным сервера; `null` — старый ответ API.
  final QuotaInfo? quota;

  /// Прошлое окно той же длины; `null` — старый ответ API.
  final PreviousWindow? previous;

  /// Тренд к прошлому окну; для старых ответов — [TrendInfo.none].
  final TrendInfo trend;
}
