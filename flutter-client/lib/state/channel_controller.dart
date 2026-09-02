import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/secure_store.dart';

/// Owns the answer to "which control plane is this app talking to": PROD
/// (`api.gluk.tech`) or BETA (`beta-api.gluk.tech`).
///
/// The two stacks are separate deployments with separate databases and separate
/// signing secrets, so switching is not a URL swap:
///
///  1. [SecureStore.channelId] is repointed, so the refresh token, device id and
///     WireGuard key pair of the *target* channel are the ones in play;
///  2. [ApiClient.setBaseUrl] drops the in-memory tokens before the host
///     changes, so a PROD access token is never sent to the BETA host;
///  3. the owner of the app state (main.dart) is called back to re-bootstrap
///     auth and reset VPN state for the new channel.
///
/// Nothing is copied between channels, and the channel that is left keeps its
/// stored session: flipping BETA on and off returns to the same PROD login.
class ChannelController extends ChangeNotifier {
  ChannelController({
    required ApiClient api,
    required SecureStore store,
    Future<void> Function(AppChannel channel)? onChannelChanged,
  })  : _api = api,
        _store = store,
        _onChannelChanged = onChannelChanged;

  final ApiClient _api;
  final SecureStore _store;
  final Future<void> Function(AppChannel channel)? _onChannelChanged;

  AppChannel _active = AppConfig.defaultChannel;
  bool _switching = false;
  bool _probing = false;
  String? _error;

  final Map<AppChannel, ChannelVersion> _versions = <AppChannel, ChannelVersion>{};
  final Map<AppChannel, String> _unreachable = <AppChannel, String>{};

  AppChannel get active => _active;
  bool get isBeta => _active.isBeta;
  bool get switching => _switching;
  bool get probing => _probing;
  String? get error => _error;
  String get baseUrl => AppConfig.baseUrlFor(_active);

  /// The switch is hidden when beta was compiled out, and when the build was
  /// pinned to a custom host with `--dart-define=API_BASE_URL=...`, where a
  /// prod/beta split would be a lie.
  bool get canSwitch =>
      AppConfig.betaChannelAvailable && !AppConfig.hasBaseUrlOverride;

  /// ROUND 5: the BETA switch belongs to admins only.
  ///
  /// A normal account gets PROD and nothing else. The server enforces this
  /// anyway - a non-admin is refused on the beta control plane and cannot
  /// register there - so showing the switch only ever produced a confusing
  /// failure. Hiding it is the honest UI, and hiding it here rather than in one
  /// screen means the phone, the PC and the diagnostics panel all agree.
  bool canSwitchAs(AuthUser? user) => canSwitch && (user?.isAdmin ?? false);

  /// ROUND 12: nobody stays on BETA without an admin session.
  ///
  /// Round 11 hid the channel switch from non-admins and left a trap behind. A
  /// device moved to BETA by an earlier build kept talking to the beta plane
  /// for ever, and the control that would have moved it back was no longer on
  /// screen. Beta is a separate deployment with its own database, so the
  /// account is not there at all: the whole thing reads as "my password stopped
  /// working", with nothing to suggest the app is asking the wrong server.
  ///
  /// Signed out counts as "not an admin" on purpose - a login screen pointed
  /// at beta can only ever refuse the person typing into it.
  ///
  /// Safe to call repeatedly: once the channel is PROD this returns at once,
  /// so the [switchTo] callback re-running bootstrap cannot loop.
  Future<void> demoteIfNotAdmin(AuthUser? user) async {
    if (!_active.isBeta) return;
    if (user?.isAdmin ?? false) return;
    debugPrint('channel: beta is admin-only, moving back to prod');
    await switchTo(AppChannel.prod);
  }

  /// Version reported by `GET /api/version`, or null if never probed / down.
  ChannelVersion? versionOf(AppChannel channel) => _versions[channel];

  /// Why the last probe of [channel] failed, for the "BETA is off" hint.
  String? unreachableReason(AppChannel channel) => _unreachable[channel];

  /// True when BETA answered its last probe: the BETA service is up and
  /// switching to it will not strand the user on a dead host.
  bool get betaReachable => _versions.containsKey(AppChannel.beta);

  /// "PROD 1.0.0" / "PROD 1.0.0 · BETA 1.2.0" for the Settings header.
  String get versionSummary {
    final List<String> parts = <String>[];
    for (final AppChannel channel in AppChannel.values) {
      final ChannelVersion? version = _versions[channel];
      if (version != null) parts.add(version.label);
    }
    if (parts.isEmpty) return 'version unknown';
    return parts.join(' \u00b7 ');
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Restores the stored selection. Must run before `AuthController.bootstrap()`,
  /// otherwise the session of the wrong channel would be restored.
  Future<void> restore() async {
    AppChannel stored = AppChannel.fromId(await _store.readActiveChannel());
    if (stored.isBeta && !canSwitch) stored = AppChannel.prod;
    _apply(stored);
    notifyListeners();
  }

  void _apply(AppChannel channel) {
    _active = channel;
    // Order matters: scope the storage first, then repoint the client (which
    // clears whatever tokens the previous channel had put in memory).
    _store.channelId = channel.id;
    _api.setBaseUrl(AppConfig.baseUrlFor(channel));
  }

  Future<bool> switchTo(AppChannel channel) async {
    if (_switching) return false;
    if (channel == _active) return true;
    if (channel.isBeta && !canSwitch) {
      _error = 'The beta channel is not available for this account.';
      notifyListeners();
      return false;
    }

    _switching = true;
    _error = null;
    notifyListeners();
    try {
      _apply(channel);
      await _store.writeActiveChannel(channel.id);
      await _onChannelChanged?.call(channel);
      await probe(channel);
      return true;
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// Settings exposes this as a plain BETA on/off switch.
  Future<bool> setBetaEnabled(bool enabled) =>
      switchTo(enabled ? AppChannel.beta : AppChannel.prod);

  /// Reads `GET /api/version` for one channel.
  ///
  /// The active channel is probed with the shared client; the other one gets a
  /// throwaway client so that probing never touches the live session. The call
  /// is unauthenticated, so it works on the login screen too.
  Future<ChannelVersion?> probe(AppChannel channel) async {
    final bool isActive = channel == _active;
    final ApiClient client =
        isActive ? _api : ApiClient(baseUrl: AppConfig.baseUrlFor(channel));
    try {
      final ChannelVersion version = await client.version();
      _versions[channel] = version;
      _unreachable.remove(channel);
      return version;
    } on ApiException catch (error) {
      _versions.remove(channel);
      _unreachable[channel] = error.message;
      return null;
    } catch (_) {
      _versions.remove(channel);
      _unreachable[channel] = 'Unexpected error while reading the version.';
      return null;
    } finally {
      if (!isActive) client.close();
      notifyListeners();
    }
  }

  /// Probes every channel this build can use, in parallel, for the Settings
  /// panel that compares "PROD 1.0.0" against "BETA 1.2.0".
  Future<void> probeAll() async {
    if (_probing) return;
    _probing = true;
    notifyListeners();
    try {
      final List<AppChannel> targets = <AppChannel>[
        AppChannel.prod,
        if (canSwitch) AppChannel.beta,
      ];
      await Future.wait(targets.map(probe));
    } finally {
      _probing = false;
      notifyListeners();
    }
  }
}
