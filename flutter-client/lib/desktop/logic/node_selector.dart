import '../../models/models.dart';

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

/// True when the node looks like infrastructure rather than a product server.
///
/// Matching is done on word boundaries so a legitimate city like "Detroit"
/// is not caught by the "dev" marker, and "Testov" is not caught by "test".
bool isInternalNode(VpnNodeInfo node) {
  final haystack = <String?>[node.id, node.name, node.host]
      .whereType<String>()
      .map((String s) => s.toLowerCase())
      .join(' ');
  if (haystack.isEmpty) return false;

  for (final marker in kInternalNodeMarkers) {
    final re = RegExp('(^|[^a-z0-9])' + marker + '([^a-z0-9]|\$)');
    if (re.hasMatch(haystack)) return true;
  }
  return false;
}

/// Nodes that may be rendered in the server list.
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
/// Only considers nodes that are online, connectable and visible to this
/// build. A small bonus is given to the user's own country so that Auto does
/// not bounce across continents when two nodes score almost identically.
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
      score += 0.02;
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
