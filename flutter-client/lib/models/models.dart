/// Data models mirroring the control-plane JSON contracts.
///
/// Parsing is deliberately defensive: the server may add fields later without
/// breaking an already installed APK, and a malformed response must surface as
/// a normal error instead of a crash.
library;

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double? _asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool _asBool(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return fallback;
}

String _asString(Object? value, [String fallback = '']) {
  if (value is String) return value;
  if (value == null) return fallback;
  return value.toString();
}

String? _asStringOrNull(Object? value) {
  if (value == null) return null;
  final String text = _asString(value);
  return text.isEmpty ? null : text;
}

DateTime? _asDate(Object? value) {
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value)?.toLocal();
  return null;
}

List<String> _asStringList(Object? value) {
  if (value is List) {
    return value.map(_asString).where((String e) => e.isNotEmpty).toList();
  }
  if (value is String) {
    return value
        .split(',')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
  }
  return const <String>[];
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const <String, dynamic>{};
}

/// Access + refresh token pair issued by the control plane.
///
/// `toString` is overridden on purpose: token values must never end up in logs
/// or crash reports.
class TokenBundle {
  const TokenBundle({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    this.refreshTokenExpiresAt,
    this.deviceId,
  });

  factory TokenBundle.fromJson(Map<String, dynamic> json) {
    final int expiresIn = _asInt(json['expiresIn'], 900);
    return TokenBundle(
      accessToken: _asString(json['accessToken']),
      accessTokenExpiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
      refreshToken: _asString(json['refreshToken']),
      refreshTokenExpiresAt: _asDate(json['refreshTokenExpiresAt']),
      deviceId: _asStringOrNull(json['deviceId']),
    );
  }

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime? refreshTokenExpiresAt;

  /// Set once the token is bound to a registered device (device scope).
  final String? deviceId;

  /// Refresh a little early so a slow request never travels with a dead token.
  bool get isExpiring =>
      DateTime.now().isAfter(accessTokenExpiresAt.subtract(const Duration(seconds: 30)));

  TokenBundle withDeviceId(String? id) => TokenBundle(
        accessToken: accessToken,
        accessTokenExpiresAt: accessTokenExpiresAt,
        refreshToken: refreshToken,
        refreshTokenExpiresAt: refreshTokenExpiresAt,
        deviceId: id ?? deviceId,
      );

  @override
  String toString() => 'TokenBundle(deviceId: $deviceId, redacted)';
}

class AuthUser {
  const AuthUser({
    required this.id,
    required this.username,
    required this.status,
    required this.isAdmin,
    required this.maxDevices,
    required this.maxConcurrentSessions,
    this.publicId = '',
    this.email,
    this.emailVerified = false,
    this.originCountry,
    this.originCountryCode,
    this.originRegion,
    this.createdAt,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> origin = _asMap(json['origin']);
    return AuthUser(
      id: _asString(json['id']),
      publicId: _asString(json['publicId']),
      username: _asString(json['username']),
      email: _asStringOrNull(json['email']),
      emailVerified: _asBool(json['emailVerified']),
      status: _asString(json['status'], 'ACTIVE'),
      isAdmin: _asBool(json['isAdmin']),
      maxDevices: _asInt(json['maxDevices'], 3),
      maxConcurrentSessions: _asInt(json['maxConcurrentSessions'], 1),
      originCountry: _asStringOrNull(origin['country']),
      originCountryCode: _asStringOrNull(origin['countryCode']),
      originRegion: _asStringOrNull(origin['region']),
      createdAt: _asDate(json['createdAt']),
    );
  }

  /// Internal UUID. Used in API paths, never shown to the user.
  final String id;

  /// Immutable 8-digit account number, always starting with 1 (`10758930`).
  /// Random, so it reveals neither signup order nor how many accounts exist.
  /// The nickname and the email are editable, this is not: support, search and
  /// bans key on it. Empty only against a control server older than this build.
  final String publicId;

  final String username;

  /// Second login identity. Either identity works at the login screen.
  final String? email;
  final bool emailVerified;

  final String status;
  final bool isAdmin;
  final int maxDevices;
  final int maxConcurrentSessions;

  /// Approximate origin, resolved server-side from the login IP: country and
  /// region only. This app asks for no location permission and stores no
  /// coordinates; the map marker is drawn at the centre of the country.
  final String? originCountry;
  final String? originCountryCode;
  final String? originRegion;

  final DateTime? createdAt;

  bool get isActive => status == 'ACTIVE';

  /// Account number for the profile card. Empty string when unknown, so the UI
  /// can hide the row instead of showing a placeholder.
  String get publicIdLabel => publicId.isEmpty ? '' : 'ID $publicId';

  /// "Germany" or "Germany, Hesse" - whatever the server could resolve.
  String? get originLabel {
    final String country = originCountry ?? '';
    final String region = originRegion ?? '';
    if (country.isEmpty) return region.isEmpty ? null : region;
    if (region.isEmpty || region == country) return country;
    return '$country, $region';
  }

  AuthUser copyWith({String? username, String? email, bool? emailVerified}) =>
      AuthUser(
        id: id,
        publicId: publicId,
        username: username ?? this.username,
        email: email ?? this.email,
        emailVerified: emailVerified ?? this.emailVerified,
        status: status,
        isAdmin: isAdmin,
        maxDevices: maxDevices,
        maxConcurrentSessions: maxConcurrentSessions,
        originCountry: originCountry,
        originCountryCode: originCountryCode,
        originRegion: originRegion,
        createdAt: createdAt,
      );
}

/// Build fingerprint of one control plane, from `GET /api/version`.
///
/// Settings shows one of these per channel ("PROD 1.0.0" / "BETA 1.2.0") and
/// uses a failed request as the signal that BETA is currently switched off.
class ChannelVersion {
  const ChannelVersion({
    required this.channel,
    required this.version,
    this.commit = '',
    this.migration = '',
    this.release = '',
    this.releasedAt,
    this.databaseUp = true,
  });

  factory ChannelVersion.fromJson(Map<String, dynamic> json) => ChannelVersion(
        channel: _asString(json['channel'], 'prod'),
        version: _asString(json['version'], '0.0.0'),
        commit: _asString(json['commit']),
        migration: _asString(json['migration']),
        release: _asString(json['release']),
        releasedAt: _asDate(json['releasedAt']),
        databaseUp: _asString(json['database'], 'up') == 'up',
      );

  final String channel;
  final String version;
  final String commit;

  /// Which deployed release actually answered (`20260821-174500`).
  ///
  /// `version` comes from package.json, so a promote that copies beta's code
  /// into prod leaves it unchanged - which is exactly why "the prod version
  /// never changes after a promote" looked like a bug. This field is the
  /// release directory the process is running from, so it changes every time.
  final String release;

  /// Last applied Prisma migration, so a promote can be checked for a schema
  /// mismatch before it is started.
  final String migration;
  final DateTime? releasedAt;
  final bool databaseUp;

  bool get isBeta => channel.toLowerCase() == 'beta';

  String get channelLabel => channel.toUpperCase();

  String get label => '$channelLabel $version';

  /// What Settings shows for the running deployment.
  String get releaseLabel => release.isEmpty ? '\u2014' : release;

  String get commitShort =>
      commit.length <= 7 ? commit : commit.substring(0, 7);
}

/// Result of `POST /api/auth/username`.
class UsernameChangeResult {
  const UsernameChangeResult({
    required this.publicId,
    required this.username,
    required this.changed,
  });

  factory UsernameChangeResult.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['user'];
    final Map<String, dynamic> user =
        raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    return UsernameChangeResult(
      publicId: _asString(user['publicId']),
      username: _asString(user['username']),
      changed: _asBool(json['changed']),
    );
  }

  final String publicId;
  final String username;

  /// False when the requested name equalled the current one: the UI then says
  /// nothing changed instead of claiming a rename.
  final bool changed;
}

class SubscriptionInfo {
  const SubscriptionInfo({required this.status, this.expiresAt});

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) => SubscriptionInfo(
        status: _asString(json['status'], 'EXPIRED'),
        expiresAt: _asDate(json['expiresAt']),
      );

  final String status;
  final DateTime? expiresAt;

  bool get isActive =>
      status == 'ACTIVE' && (expiresAt?.isAfter(DateTime.now()) ?? false);
}

/// Client-facing node projection returned by `GET /api/nodes`.
class VpnNodeInfo {
  const VpnNodeInfo({
    required this.id,
    required this.name,
    required this.country,
    required this.countryCode,
    required this.host,
    required this.port,
    required this.status,
    required this.online,
    required this.connectable,
    required this.loadPercent,
    required this.activePeers,
    required this.capacity,
    this.region,
    this.city,
    this.title = '',
    this.subtitle = '',
    this.pingTarget = '',
    this.cpuPercent,
    this.ramPercent,
    this.uptimeSeconds,
    this.agentVersion,
    this.lastHeartbeat,
  });

  factory VpnNodeInfo.fromJson(Map<String, dynamic> json) => VpnNodeInfo(
        id: _asString(json['id']),
        name: _asString(json['name']),
        country: _asString(json['country']),
        countryCode: _asString(json['countryCode']),
        region: _asStringOrNull(json['region']),
        city: _asStringOrNull(json['city']),
        title: _asString(json['title']),
        subtitle: _asString(json['subtitle']),
        pingTarget: _asString(json['pingTarget']),
        host: _asString(json['host']),
        port: _asInt(json['port'], 51820),
        status: _asString(json['status'], 'OFFLINE'),
        online: _asBool(json['online']),
        connectable: _asBool(json['connectable']),
        loadPercent: _asInt(json['loadPercent']),
        activePeers: _asInt(json['activePeers']),
        capacity: _asInt(json['capacity']),
        cpuPercent: _asDouble(json['cpuPercent']),
        ramPercent: _asDouble(json['ramPercent']),
        uptimeSeconds: json['uptimeSeconds'] == null ? null : _asInt(json['uptimeSeconds']),
        agentVersion: _asStringOrNull(json['agentVersion']),
        lastHeartbeat: _asDate(json['lastHeartbeat']),
      );

  final String id;

  /// Internal handle ("de-01"). Debug and admin only - the user-facing rows use
  /// [displayTitle] / [displaySubtitle], so a node name never reaches the UI.
  final String name;

  final String country;
  final String countryCode;
  final String? region;
  final String? city;

  /// Ready-made display lines from the backend ("Germany" / "Frankfurt"), so
  /// no geography is hardcoded in the app.
  final String title;
  final String subtitle;

  /// Host to measure latency against before a tunnel exists.
  final String pingTarget;

  final String host;
  final int port;

  /// PENDING | ONLINE | OFFLINE | DISABLED, as computed by the control plane.
  final String status;
  final bool online;
  final bool connectable;
  final int loadPercent;
  final int activePeers;
  final int capacity;
  final double? cpuPercent;
  final double? ramPercent;
  final int? uptimeSeconds;
  final String? agentVersion;
  final DateTime? lastHeartbeat;

  String get endpoint => '$host:$port';

  /// First line of a server row. Falls back gracefully against an older API.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    if (country.isNotEmpty) return country;
    return countryCode;
  }

  /// Second line: city, else region, else the country code. Never the name.
  String get displaySubtitle {
    if (subtitle.isNotEmpty) return subtitle;
    final String cityName = city ?? '';
    if (cityName.isNotEmpty) return cityName;
    final String regionName = region ?? '';
    if (regionName.isNotEmpty) return regionName;
    return countryCode;
  }

  String get latencyHost => pingTarget.isNotEmpty ? pingTarget : host;
}

/// Latency buckets behind the `///` signal bars in the server list.
///
/// Users read bars, not milliseconds; the exact figure stays available for the
/// details row.
enum PingLevel { unknown, low, medium, excellent }

PingLevel pingLevelFor(int? milliseconds) {
  if (milliseconds == null || milliseconds <= 0) return PingLevel.unknown;
  if (milliseconds < 80) return PingLevel.excellent;
  if (milliseconds < 180) return PingLevel.medium;
  return PingLevel.low;
}

extension PingLevelDisplay on PingLevel {
  /// How many of the three bars are lit.
  int get bars {
    switch (this) {
      case PingLevel.excellent:
        return 3;
      case PingLevel.medium:
        return 2;
      case PingLevel.low:
        return 1;
      case PingLevel.unknown:
        return 0;
    }
  }

  String get label {
    switch (this) {
      case PingLevel.excellent:
        return 'Excellent';
      case PingLevel.medium:
        return 'Medium';
      case PingLevel.low:
        return 'Low';
      case PingLevel.unknown:
        return '';
    }
  }
}

class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.deviceName,
    required this.status,
    this.platform,
    this.createdAt,
    this.lastSeen,
    this.isCurrent = false,
    this.connected = false,
    this.connectedNodeName,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> node = _asMap(json['connectedNode']);
    return DeviceInfo(
      id: _asString(json['id']),
      deviceName: _asString(json['deviceName']),
      status: _asString(json['status'], 'ACTIVE'),
      platform: _asStringOrNull(json['platform']),
      createdAt: _asDate(json['createdAt']),
      lastSeen: _asDate(json['lastSeen']),
      isCurrent: _asBool(json['isCurrent']),
      connected: _asBool(json['connected']),
      connectedNodeName: _asStringOrNull(node['name']),
    );
  }

  final String id;
  final String deviceName;
  final String status;
  final String? platform;
  final DateTime? createdAt;
  final DateTime? lastSeen;
  final bool isCurrent;
  final bool connected;
  final String? connectedNodeName;

  bool get isActive => status == 'ACTIVE';
}

/// Everything the phone needs to build a WireGuard tunnel, as returned by
/// `POST /api/vpn/connect`.
///
/// Note what is NOT here: the client private key. It is generated on the device
/// and never travels over the network in either direction.
class TunnelConfig {
  const TunnelConfig({
    required this.sessionId,
    required this.interfaceAddress,
    required this.dns,
    required this.mtu,
    required this.peerPublicKey,
    required this.endpoint,
    required this.allowedIps,
    required this.persistentKeepalive,
  });

  factory TunnelConfig.fromJson(Map<String, dynamic> json) => TunnelConfig(
        sessionId: _asString(json['sessionId']),
        interfaceAddress: _asString(json['interfaceAddress']),
        dns: _asStringList(json['dns']),
        mtu: _asInt(json['mtu'], 1420),
        peerPublicKey: _asString(json['peerPublicKey']),
        endpoint: _asString(json['endpoint']),
        allowedIps: _asStringList(json['allowedIps']),
        persistentKeepalive: _asInt(json['persistentKeepalive'], 25),
      );

  final String sessionId;

  /// The address assigned to this device, e.g. `10.8.0.5/32`.
  final String interfaceAddress;
  final List<String> dns;
  final int mtu;
  final String peerPublicKey;
  final String endpoint;
  final List<String> allowedIps;
  final int persistentKeepalive;

  String get assignedIp => interfaceAddress.split('/').first;

  /// Best-effort address of the node inside the tunnel, used as the ping target.
  ///
  /// The client only receives its own /32, so the gateway is derived from the
  /// assigned address: the node holds `<prefix>.1` (10.8.0.1/24 in wg0.conf).
  String? get gatewayIp {
    final List<String> parts = assignedIp.split('.');
    if (parts.length != 4) return null;
    return '${parts[0]}.${parts[1]}.${parts[2]}.1';
  }

  /// Builds the wg-quick config handed to the tunnel plugin.
  ///
  /// The private key is injected here, in memory, at the last possible moment.
  /// Never log the return value: use [describeForLog] instead.
  String toWgQuickConfig({required String privateKeyBase64}) {
    final StringBuffer out = StringBuffer()
      ..writeln('[Interface]')
      ..writeln('PrivateKey = $privateKeyBase64')
      ..writeln('Address = $interfaceAddress');
    if (dns.isNotEmpty) out.writeln('DNS = ${dns.join(', ')}');
    out
      ..writeln('MTU = $mtu')
      ..writeln()
      ..writeln('[Peer]')
      ..writeln('PublicKey = $peerPublicKey')
      ..writeln(
        'AllowedIPs = ${allowedIps.isEmpty ? '0.0.0.0/0' : allowedIps.join(', ')}',
      )
      ..writeln('Endpoint = $endpoint')
      ..writeln('PersistentKeepalive = $persistentKeepalive');
    return out.toString();
  }

  /// Log-safe summary: no key material at all.
  String describeForLog() =>
      'tunnel(session: $sessionId, address: $interfaceAddress, endpoint: $endpoint, '
      'mtu: $mtu, dns: ${dns.length}, allowedIps: ${allowedIps.join(' ')})';

  @override
  String toString() => describeForLog();
}

/// A VPN session as the control plane sees it.
class VpnSessionInfo {
  const VpnSessionInfo({
    required this.id,
    required this.status,
    required this.assignedVpnIp,
    required this.bytesRx,
    required this.bytesTx,
    required this.durationSec,
    this.connectedAt,
    this.disconnectedAt,
    this.lastHandshakeAt,
    this.nodeId,
    this.nodeName,
    this.nodeCountry,
    this.nodeCountryCode,
    this.nodeHost,
    this.deviceId,
  });

  factory VpnSessionInfo.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> node = _asMap(json['node']);
    return VpnSessionInfo(
      id: _asString(json['id']),
      status: _asString(json['status'], 'PENDING'),
      assignedVpnIp: _asString(json['assignedVpnIp']),
      bytesRx: _asInt(json['bytesRx']),
      bytesTx: _asInt(json['bytesTx']),
      durationSec: _asInt(json['durationSec']),
      connectedAt: _asDate(json['connectedAt']),
      disconnectedAt: _asDate(json['disconnectedAt']),
      lastHandshakeAt: _asDate(json['lastHandshakeAt']),
      nodeId: _asStringOrNull(node['id']),
      nodeName: _asStringOrNull(node['name']),
      nodeCountry: _asStringOrNull(node['country']),
      nodeCountryCode: _asStringOrNull(node['countryCode']),
      nodeHost: _asStringOrNull(node['host']),
      deviceId: _asStringOrNull(json['deviceId']),
    );
  }

  final String id;

  /// PENDING until the node confirms the peer was added, then ACTIVE.
  final String status;
  final String assignedVpnIp;
  final int bytesRx;
  final int bytesTx;
  final int durationSec;
  final DateTime? connectedAt;
  final DateTime? disconnectedAt;
  final DateTime? lastHandshakeAt;
  final String? nodeId;
  final String? nodeName;
  final String? nodeCountry;
  final String? nodeCountryCode;
  final String? nodeHost;
  final String? deviceId;

  bool get isLive => status == 'PENDING' || status == 'ACTIVE';
  bool get isActive => status == 'ACTIVE';
  int get totalBytes => bytesRx + bytesTx;
}

/// Result of `GET /api/vpn/status`.
class VpnStatusInfo {
  const VpnStatusInfo({
    required this.connected,
    required this.peerReady,
    required this.subscriptionActive,
    this.session,
    this.serverTime,
  });

  factory VpnStatusInfo.fromJson(Map<String, dynamic> json) {
    final Object? session = json['session'];
    return VpnStatusInfo(
      connected: _asBool(json['connected']),
      peerReady: _asBool(json['peerReady']),
      subscriptionActive: _asBool(json['subscriptionActive'], fallback: true),
      session: session == null ? null : VpnSessionInfo.fromJson(_asMap(session)),
      serverTime: _asDate(json['serverTime']),
    );
  }

  final bool connected;

  /// True once the node has actually installed the WireGuard peer.
  final bool peerReady;
  final bool subscriptionActive;
  final VpnSessionInfo? session;
  final DateTime? serverTime;
}

class LoginResult {
  const LoginResult({required this.tokens, required this.user, this.subscription});

  factory LoginResult.fromJson(Map<String, dynamic> json) => LoginResult(
        tokens: TokenBundle.fromJson(json),
        user: AuthUser.fromJson(_asMap(json['user'])),
        subscription: json['subscription'] == null
            ? null
            : SubscriptionInfo.fromJson(_asMap(json['subscription'])),
      );

  final TokenBundle tokens;
  final AuthUser user;
  final SubscriptionInfo? subscription;
}

class MeResult {
  const MeResult({
    required this.user,
    required this.activeDevices,
    this.currentDeviceId,
    this.subscription,
  });

  factory MeResult.fromJson(Map<String, dynamic> json) => MeResult(
        user: AuthUser.fromJson(_asMap(json['user'])),
        activeDevices: _asInt(json['activeDevices']),
        currentDeviceId: _asStringOrNull(json['currentDeviceId']),
        subscription: json['subscription'] == null
            ? null
            : SubscriptionInfo.fromJson(_asMap(json['subscription'])),
      );

  final AuthUser user;
  final int activeDevices;
  final String? currentDeviceId;
  final SubscriptionInfo? subscription;
}

/// Result of `POST /api/devices/register`: the device row plus device-scoped
/// tokens that replace the plain user tokens from login.
class DeviceRegistration {
  const DeviceRegistration({
    required this.device,
    required this.maxDevices,
    required this.tokens,
  });

  factory DeviceRegistration.fromJson(Map<String, dynamic> json) {
    final DeviceInfo device = DeviceInfo.fromJson(_asMap(json['device']));
    return DeviceRegistration(
      device: device,
      maxDevices: _asInt(json['maxDevices'], 3),
      tokens: TokenBundle.fromJson(json).withDeviceId(device.id),
    );
  }

  final DeviceInfo device;
  final int maxDevices;
  final TokenBundle tokens;
}

class DevicesResult {
  const DevicesResult({required this.devices, required this.maxDevices});

  factory DevicesResult.fromJson(Map<String, dynamic> json) {
    final Object? raw = json['devices'];
    return DevicesResult(
      devices: raw is List
          ? raw.map((Object? e) => DeviceInfo.fromJson(_asMap(e))).toList()
          : const <DeviceInfo>[],
      maxDevices: _asInt(json['maxDevices'], 3),
    );
  }

  final List<DeviceInfo> devices;
  final int maxDevices;
}

class ConnectResult {
  const ConnectResult({required this.session, required this.tunnel, this.node});

  factory ConnectResult.fromJson(Map<String, dynamic> json) => ConnectResult(
        session: VpnSessionInfo.fromJson(_asMap(json['session'])),
        tunnel: TunnelConfig.fromJson(_asMap(json['tunnel'])),
        node: json['node'] == null ? null : VpnNodeInfo.fromJson(_asMap(json['node'])),
      );

  final VpnSessionInfo session;
  final TunnelConfig tunnel;
  final VpnNodeInfo? node;
}
