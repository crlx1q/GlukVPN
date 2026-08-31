import '../../models/models.dart';
import '../../utils/geo_dictionary.dart';

/// Substrings that mark a node as internal-only.
///
/// Requirement 8: users must never see beta-01, test-01 and friends.
const List<String> kInternalNodeMarkers = <String>[
  'beta',
  'test',
  'staging',
  'stage',
  'dev',
  'internal',
  'canary',
  'lab',
  'tmp',
];

/// True when [text] contains an internal marker as a whole word.
bool _hasInternalMarker(String text) {
  final String haystack = text.toLowerCase();
  if (haystack.isEmpty) return false;
  for (final String marker in kInternalNodeMarkers) {
    final RegExp re = RegExp('(^|[^a-z0-9])' + marker + r'([^a-z0-9]|$)');
    if (re.hasMatch(haystack)) return true;
  }
  return false;
}

/// True when the node looks like infrastructure rather than a product server.
///
/// Matching is done on word boundaries so a legitimate city like "Detroit"
/// is not caught by the "dev" marker, and "Testov" is not caught by "test".
bool isInternalNode(VpnNodeInfo node) {
  final String haystack = <String?>[node.id, node.name, node.host]
      .whereType<String>()
      .map((String s) => s.toLowerCase())
      .join(' ');
  return _hasInternalMarker(haystack);
}

/// Nodes that may be *advertised* to the user.
///
/// Internal builds (GLUK_INTERNAL=true) see everything; production builds
/// never do, regardless of what the API returns.
List<VpnNodeInfo> visibleNodes(
  List<VpnNodeInfo> nodes, {
  bool internalBuild = false,
}) {
  if (internalBuild) return List<VpnNodeInfo>.unmodifiable(nodes);
  return List<VpnNodeInfo>.unmodifiable(
    nodes.where((VpnNodeInfo n) => !isInternalNode(n)),
  );
}

/// True when the whole fleet was filtered out as internal.
///
/// This is the state that broke the first Windows release: the account had
/// exactly one node, its handle matched an internal marker, and the client
/// ended up with an empty list and a dead Connect button.
bool fleetIsInternalOnly(
  List<VpnNodeInfo> nodes, {
  bool internalBuild = false,
}) {
  if (nodes.isEmpty) return false;
  return visibleNodes(nodes, internalBuild: internalBuild).isEmpty;
}

/// Nodes the client may actually select and connect to.
///
/// Same filter as [visibleNodes], with one deliberate difference: hiding a
/// node must never leave the user with nothing. When filtering would empty the
/// list, the raw fleet is returned instead - the node is still usable, it just
/// must never be *named* in the UI. Use [publicNodeTitle] and
/// [publicNodeSubtitle] for that, they never expose a handle.
///
/// Requirement 8 is about not leaking internal identifiers, not about refusing
/// to work.
List<VpnNodeInfo> selectableNodes(
  List<VpnNodeInfo> nodes, {
  bool internalBuild = false,
  bool allowFallback = true,
}) {
  final List<VpnNodeInfo> public =
      visibleNodes(nodes, internalBuild: internalBuild);
  if (public.isNotEmpty || !allowFallback || nodes.isEmpty) return public;
  return List<VpnNodeInfo>.unmodifiable(nodes);
}

/// First line of a server row, guaranteed free of internal identifiers.
///
/// Tries the backend display fields, then the geography, and only ever falls
/// back to a neutral label. The node handle, host and id are never candidates.
String publicNodeTitle(VpnNodeInfo node, {String fallback = 'VPN server'}) {
  for (final String candidate in <String>[
    node.title,
    node.country,
    node.city ?? '',
    node.region ?? '',
  ]) {
    if (candidate.isNotEmpty && !_hasInternalMarker(candidate)) return candidate;
  }
  final String code = node.countryCode;
  if (code.isNotEmpty && !_hasInternalMarker(code)) return code.toUpperCase();
  return fallback;
}

/// Second line of a server row: city, region or country - never the handle.
///
/// Returns null when there is nothing meaningful to add, so the caller can
/// drop the line instead of printing the title twice.
String? publicNodeSubtitle(VpnNodeInfo node) {
  final String title = publicNodeTitle(node);
  for (final String candidate in <String>[
    node.subtitle,
    node.city ?? '',
    node.region ?? '',
    node.country,
  ]) {
    if (candidate.isEmpty) continue;
    if (_hasInternalMarker(candidate)) continue;
    if (candidate == title) continue;
    return candidate;
  }
  return null;
}

/// "Frankfurt, Германия" - city first, country second, both translated.
///
/// ROUND 5: the requested label shape, and the reason a German node used to
/// read as a bare "DE" on Windows. [publicNodeTitle] and [publicNodeSubtitle]
/// keep their old contracts (the privacy tests pin them down); this is the
/// display label built on top of them, and it goes through the same dictionary
/// as `extension/lib/geo.js` so all three clients agree.
String publicNodeLocation(
  VpnNodeInfo node, {
  bool russian = true,
  String fallback = 'VPN server',
}) {
  final String city = _clean(node.city);
  final String code = _clean(node.countryCode);
  final String country = _clean(node.country);

  final String label = formatNodeLocation(
    city: city,
    countryCode: code,
    countryName: country.isEmpty ? null : country,
    region: _clean(node.region),
    russian: russian,
  );
  if (label.isNotEmpty) return label;

  // Nothing geographic survived the internal-marker filter.
  return publicNodeTitle(node, fallback: fallback);
}

/// Drops values that would leak an internal handle into the UI.
String _clean(String? value) {
  final String text = (value ?? '').trim();
  if (text.isEmpty) return '';
  if (_hasInternalMarker(text)) return '';
  return text;
}

/// Quality score in [0..1]; higher is better.
///
/// Weighting reflects what users actually feel:
///   latency 55%, current load 30%, spare capacity 15%.
double nodeScore(VpnNodeInfo node, {int? measuredPingMs}) {
  // Latency: 20 ms or better is perfect, 300 ms or worse is useless.
  final ping = measuredPingMs;
  final double pingGrade;
  if (ping == null) {
    pingGrade = 0.55; // unknown: assume mediocre rather than great
  } else if (ping <= 20) {
    pingGrade = 1.0;
  } else if (ping >= 300) {
    pingGrade = 0.0;
  } else {
    pingGrade = 1.0 - ((ping - 20) / 280.0);
  }

  // Load: reported as a percentage.
  final load = node.loadPercent;
  final double loadGrade;
  if (load == null) {
    loadGrade = 0.6;
  } else {
    final clamped = load.clamp(0, 100).toDouble();
    loadGrade = 1.0 - (clamped / 100.0);
  }

  // Capacity headroom: how much room is left before the node fills up.
  final capacity = node.capacity;
  final peers = node.activePeers;
  final double headroom;
  if (capacity == null || capacity <= 0 || peers == null) {
    headroom = 0.6;
  } else {
    final free = (capacity - peers) / capacity;
    headroom = free.clamp(0.0, 1.0).toDouble();
  }

  return (0.55 * pingGrade) + (0.30 * loadGrade) + (0.15 * headroom);
}

/// Result of automatic server selection.
class AutoNodeChoice {
  const AutoNodeChoice(this.node, this.reason);

  const AutoNodeChoice.empty(this.reason) : node = null;

  final VpnNodeInfo? node;

  /// Human/log readable justification, e.g. "score=0.81 ping=42ms load=18%".
  final String reason;

  bool get isEmpty => node == null;
}

/// Picks the best node for the Auto / Best Server option.
///
/// Only considers nodes that are online, connectable and advertised to this
/// build. A small bonus is given to the user's own country so that Auto does
/// not bounce across continents when two nodes score almost identically.
///
/// Callers that must always end up with a target (the connect path) fall back
/// to [selectableNodes] when this returns empty.
AutoNodeChoice pickBestNode(
  List<VpnNodeInfo> nodes, {
  Map<String, int> pings = const <String, int>{},
  bool internalBuild = false,
  String? preferCountryCode,
}) {
  final candidates = visibleNodes(nodes, internalBuild: internalBuild)
      .where((VpnNodeInfo n) => n.online && n.connectable)
      .toList();

  if (candidates.isEmpty) {
    return const AutoNodeChoice.empty('no_available_nodes');
  }

  VpnNodeInfo? best;
  double bestScore = -1.0;
  int? bestPing;

  final prefer = preferCountryCode?.toUpperCase();

  for (final node in candidates) {
    final ping = pings[node.id];
    var score = nodeScore(node, measuredPingMs: ping);

    if (prefer != null &&
        prefer.isNotEmpty &&
        node.countryCode?.toUpperCase() == prefer) {
      score += 0.06;
    }

    if (score > bestScore) {
      bestScore = score;
      best = node;
      bestPing = ping;
    }
  }

  if (best == null) {
    return const AutoNodeChoice.empty('no_scored_nodes');
  }

  final pingLabel = bestPing == null ? 'n/a' : '${bestPing}ms';
  final loadLabel =
      best.loadPercent == null ? 'n/a' : '${best.loadPercent!.round()}%';

  return AutoNodeChoice(
    best,
    'score=${bestScore.toStringAsFixed(2)} ping=$pingLabel load=$loadLabel',
  );
}

/// Requirement 8: free users get Auto only, paid users may choose manually.
bool manualSelectionAllowed(SubscriptionInfo? subscription) {
  return subscription?.isActive == true;
}
