import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../services/secure_store.dart';

/// What [ChannelController.trySwitch] decided.
///
/// The UI renders these; it never has to know why a switch was refused in
/// terms of HTTP. Only [switched] means the app now talks to another control
/// plane - every other value leaves the active channel and its session intact.
enum ChannelSwitchResult {
  /// The app now talks to the target channel and the session was rebuilt from
  /// that channel's own stored credentials.
  switched,

  /// The target was already the active channel; nothing happened.
  alreadyActive,

  /// Another switch (or its availability probe) is still in flight.
  busy,

  /// This build, or this account, may not use the target channel.
  notAllowed,

  /// `GET /api/version` on the target did not answer within the probe timeout.
  /// Nothing changed: the current channel stays selected and its session is
  /// untouched, so a flip towards a dead BETA host can no longer sign the user
  /// out into the void.
  targetUnavailable,
}

/// Reachability probe of one control plane: the version it reports, or `null`
/// when it is down. Injected in tests so the decision logic runs offline.
typedef ChannelProbe = Future<ChannelVersion?> Function(String baseUrl);

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
    ChannelProbe? probeChannel,
  })  : _api = api,
        _store = store,
        _onChannelChanged = onChannelChanged,
        _probeChannel = probeChannel;

  final ApiClient _api;
  final SecureStore _store;
  final Future<void> Function(AppChannel channel)? _onChannelChanged;

  /// Overrides [ApiClient.probeChannel]; `null` means the real network.
  final ChannelProbe? _probeChannel;

  AppChannel _active = AppConfig.defaultChannel;

  /// True when BETA was flipped on by hand during this run of the app.
  ///
  /// Deliberately not persisted: it separates \"this device was left on beta by
  /// an old build\" from \"the person in front of the screen just asked for
  /// beta\", and only the second one survives being signed out.
  bool _explicitBetaChoice = false;
  bool _switching = false;
  bool _probing = false;
  String? _error;

  /// The channel a [trySwitch] is currently probing or moving to.
  AppChannel? _pendingTarget;

  /// Outcome of the last [trySwitch], and which channel it was aimed at.
  ChannelSwitchResult? _lastResult;
  AppChannel? _lastTarget;

  final Map<AppChannel, ChannelVersion> _versions = <AppChannel, ChannelVersion>{};
  final Map<AppChannel, String> _unreachable = <AppChannel, String>{};

  AppChannel get active => _active;
  bool get isBeta => _active.isBeta;

  /// True from the moment a switch is requested until the new session has been
  /// bootstrapped - the availability probe included.
  bool get switching => _switching || _pendingTarget != null;
  bool get probing => _probing;
  String? get error => _error;
  String get baseUrl => AppConfig.baseUrlFor(_active);

  /// The channel being switched to right now, for the spinner in its pill.
  AppChannel? get pendingTarget => _pendingTarget;

  ChannelSwitchResult? get lastSwitchResult => _lastResult;
  AppChannel? get lastSwitchTarget => _lastTarget;

  /// The channel the last switch attempt could not reach, or `null` when the
  /// last attempt did not fail that way. The UI turns this into "the beta
  /// server is currently unavailable" in the interface language.
  AppChannel? get unavailableChannel =>
      _lastResult == ChannelSwitchResult.targetUnavailable ? _lastTarget : null;

  /// The switch is hidden when beta was compiled out, and when the build was
  /// pinned to a custom host with `--dart-define=API_BASE_URL=...`, where a
  /// prod/beta split would be a lie.
  bool get canSwitch =>
      AppConfig.betaChannelAvailable && !AppConfig.hasBaseUrlOverride;

  /// Who may see and use the channel switch: administrators, accounts flagged
  /// as beta testers, and anybody running an internal build.
  ///
  /// ROUND 5 made the switch admin-only, because the beta control plane
  /// refuses everyone else and a switch that can only fail is a trap. Testers
  /// are now let in by the server too (`AuthUser.isTester`), so the rule grows
  /// by exactly that flag - one predicate, shared by the card in Settings and
  /// by the start-up demotion below, so the two can never disagree.
  bool isEntitled(AuthUser? user) =>
      (user?.canUseBetaChannel ?? false) || AppConfig.internalBuild;

  /// The channel card is shown when the build can switch at all ([canSwitch])
  /// *and* the person in front of the screen is entitled to ([isEntitled]).
  bool canSwitchFor(AuthUser? user) => canSwitch && isEntitled(user);

  /// Old name for [canSwitchFor]; testers were not part of the rule then.
  @Deprecated('Use canSwitchFor(user): testers count as well as admins.')
  bool canSwitchAs(AuthUser? user) => canSwitchFor(user);

  /// ROUND 12: nobody stays on BETA without an entitled session.
  ///
  /// Round 11 hid the channel switch from non-admins and left a trap behind. A
  /// device moved to BETA by an earlier build kept talking to the beta plane
  /// for ever, and the control that would have moved it back was no longer on
  /// screen. Beta is a separate deployment with its own database, so the
  /// account is not there at all: the whole thing reads as "my password stopped
  /// working", with nothing to suggest the app is asking the wrong server.
  ///
  /// Safe to call repeatedly: once the channel is PROD this returns at once,
  /// so the [switchTo] callback re-running bootstrap cannot loop.
  ///
  /// ROUND 25: signed out is not the same as "not entitled".
  ///
  /// Round 12 demoted a signed-out app to PROD unconditionally, and that broke
  /// the only way into BETA: an admin flipped the switch, the demotion fired
  /// before anyone could log in, and "Sign in" opened a link carrying
  /// `api=prod` - the wrong control plane, on which the beta account does not
  /// exist. A channel chosen by hand in this run therefore survives until a
  /// session actually says otherwise; a channel merely restored from storage
  /// still gets demoted, which is the trap Round 12 was written for.
  ///
  /// Testers are treated exactly like admins here, for the same reason they
  /// see the switch: the beta plane accepts them, so there is no trap to
  /// spring. Internal builds are never demoted - the card is always on screen
  /// there, so the way back is one tap away.
  Future<void> demoteIfNotEntitled(AuthUser? user) async {
    if (!_active.isBeta) return;
    if (isEntitled(user)) return;
    if (user == null && _explicitBetaChoice) return;
    debugPrint('channel: beta is for admins and testers, moving back to prod');
    _explicitBetaChoice = false;
    await switchTo(AppChannel.prod);
  }

  /// Old name for [demoteIfNotEntitled].
  @Deprecated('Use demoteIfNotEntitled(user): testers may stay on beta.')
  Future<void> demoteIfNotAdmin(AuthUser? user) => demoteIfNotEntitled(user);

  /// Version reported by `GET /api/version`, or null if never probed / down.
  ChannelVersion? versionOf(AppChannel channel) => _versions[channel];

  /// Why the last probe of [channel] failed, for the "BETA is off" hint.
  String? unreachableReason(AppChannel channel) => _unreachable[channel];

  /// True when [channel] answered its last probe - the green dot under the
  /// pill. A channel that was never probed counts as unreachable.
  bool isReachable(AppChannel channel) => _versions.containsKey(channel);

  /// True when BETA answered its last probe: the BETA service is up and
  /// switching to it will not strand the user on a dead host.
  bool get betaReachable => isReachable(AppChannel.beta);

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

  /// Dismisses the error line: both the free-text [error] and the outcome of
  /// the last [trySwitch].
  void clearError() {
    if (_error == null && _lastResult == null) return;
    _error = null;
    _lastResult = null;
    _lastTarget = null;
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

  /// Moves to [channel] unconditionally: no availability check.
  ///
  /// This is the path back to PROD for the start-up demotion, which must work
  /// even while PROD is briefly down. Everything driven by a tap goes through
  /// [trySwitch] instead, which probes the target first.
  Future<bool> switchTo(AppChannel channel) =>
      _switchTo(channel, reprobe: true);

  Future<bool> _switchTo(AppChannel channel, {required bool reprobe}) async {
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
      _explicitBetaChoice = channel.isBeta;
      await _store.writeActiveChannel(channel.id);
      await _onChannelChanged?.call(channel);
      // trySwitch has just read the version it is switching to; asking again
      // would only delay the spinner.
      if (reprobe) await probe(channel);
      return true;
    } finally {
      _switching = false;
      notifyListeners();
    }
  }

  /// The channel card's tap handler: check that [target] answers, then switch.
  ///
  /// `GET /api/version` is asked on the target host with a 1.5 s budget, in
  /// both directions - PROD can be mid-deploy just as BETA can be switched
  /// off. When there is no answer the result is [ChannelSwitchResult
  /// .targetUnavailable] and *nothing else happens*: the active channel, its
  /// tokens and the signed-in session are exactly as they were. The outcome is
  /// kept in [lastSwitchResult] / [unavailableChannel] so the card can render
  /// it after the future completes, and cleared by [clearError] or by the next
  /// attempt.
  Future<ChannelSwitchResult> trySwitch(AppChannel target) async {
    // The public getter: a probe in flight counts as switching too.
    if (switching) return ChannelSwitchResult.busy;
    if (target == _active) return ChannelSwitchResult.alreadyActive;
    if (target.isBeta && !canSwitch) {
      _record(target, ChannelSwitchResult.notAllowed);
      return ChannelSwitchResult.notAllowed;
    }

    _pendingTarget = target;
    _lastResult = null;
    _lastTarget = null;
    _error = null;
    notifyListeners();
    try {
      final String url = AppConfig.baseUrlFor(target);
      final ChannelVersion? version = await _probeTarget(url);
      if (version == null) {
        _versions.remove(target);
        _unreachable[target] = 'No answer from $url.';
        _record(target, ChannelSwitchResult.targetUnavailable);
        return ChannelSwitchResult.targetUnavailable;
      }
      _versions[target] = version;
      _unreachable.remove(target);

      final bool moved = await _switchTo(target, reprobe: false);
      final ChannelSwitchResult result =
          moved ? ChannelSwitchResult.switched : ChannelSwitchResult.busy;
      _record(target, result);
      return result;
    } finally {
      _pendingTarget = null;
      notifyListeners();
    }
  }

  Future<ChannelVersion?> _probeTarget(String baseUrl) {
    final ChannelProbe? custom = _probeChannel;
    if (custom != null) return custom(baseUrl);
    return _api.probeChannel(baseUrl);
  }

  void _record(AppChannel target, ChannelSwitchResult result) {
    _lastTarget = target;
    _lastResult = result;
    notifyListeners();
  }

  /// Settings used to expose this as a plain BETA on/off switch. Kept for
  /// callers that still think in on/off; it now goes through [trySwitch], so
  /// a dead target is refused instead of signing the user out.
  Future<bool> setBetaEnabled(bool enabled) async {
    final ChannelSwitchResult result =
        await trySwitch(enabled ? AppChannel.beta : AppChannel.prod);
    return result == ChannelSwitchResult.switched ||
        result == ChannelSwitchResult.alreadyActive;
  }

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
