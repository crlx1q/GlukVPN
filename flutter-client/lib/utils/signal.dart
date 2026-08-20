import 'dart:math' as math;

/// Signal strength for a VPN node, in the sense a phone means it: three bars
/// that say "how good is this link right now".
///
/// The value is computed from data we actually have - the node's online flag,
/// the load it reports over its heartbeat, and the round-trip this phone just
/// measured to its ping target - never from the country it happens to sit in.
/// A node in Germany with a 300 ms round trip deserves one bar.
enum SignalStrength {
	/// Offline, disabled, or otherwise not connectable: all bars grey.
	offline,

	/// High latency or a nearly full node.
	weak,

	/// Usable, middle of the range.
	fair,

	/// Low latency and plenty of headroom.
	strong,
}

extension SignalStrengthDisplay on SignalStrength {
	/// How many of the three bars are lit.
	int get bars {
		switch (this) {
			case SignalStrength.strong:
				return 3;
			case SignalStrength.fair:
				return 2;
			case SignalStrength.weak:
				return 1;
			case SignalStrength.offline:
				return 0;
		}
	}

	/// Spoken by screen readers, and used for the (optional) caption.
	String get label {
		switch (this) {
			case SignalStrength.strong:
				return 'Excellent connection';
			case SignalStrength.fair:
				return 'Good connection';
			case SignalStrength.weak:
				return 'Weak connection';
			case SignalStrength.offline:
				return 'Unavailable';
		}
	}
}

/// Round trips at or below this are as good as it gets on mobile.
const double signalGoodPingMs = 40;

/// At or above this, latency dominates everything else.
const double signalBadPingMs = 220;

/// Load below this is free headroom.
const double signalGoodLoadPercent = 40;

/// Load at or above this means the node is effectively full.
const double signalBadLoadPercent = 95;

/// Latency carries most of the weight: users feel round-trip long before they
/// feel a node being half full.
const double signalPingWeight = 0.65;
const double signalLoadWeight = 0.35;

/// Score used when no ping sample exists yet - deliberately mid-range, so a
/// node is neither punished nor flattered for not having been measured.
const double signalUnknownPingScore = 0.55;

/// 1 when [value] is at or past [good], 0 at or past [bad], linear between.
double _grade(double value, double good, double bad) {
	if (bad == good) return 1;
	return ((bad - value) / (bad - good)).clamp(0.0, 1.0);
}

/// 0..1 quality for a node. Exposed for tests and for anything that wants a
/// continuous value rather than three buckets.
double signalScore({int? pingMs, double loadPercent = 0}) {
	final double ping = pingMs == null
			? signalUnknownPingScore
			: _grade(pingMs.toDouble(), signalGoodPingMs, signalBadPingMs);
	final double load =
			_grade(loadPercent, signalGoodLoadPercent, signalBadLoadPercent);
	return ping * signalPingWeight + load * signalLoadWeight;
}

/// Three bars for a node.
///
/// [online] is the node's heartbeat state and [available] its policy state
/// (enabled, has capacity, connectable); either one being false means grey
/// bars, because the number of bars must never suggest a server you cannot
/// actually use.
///
/// Without a ping sample the result is capped at [SignalStrength.fair]: three
/// bars is a claim about latency, and unmeasured latency is not a claim.
SignalStrength signalStrengthFor({
	required bool online,
	bool available = true,
	int? pingMs,
	double loadPercent = 0,
}) {
	if (!online || !available) return SignalStrength.offline;

	final double ping = pingMs == null
			? signalUnknownPingScore
			: _grade(pingMs.toDouble(), signalGoodPingMs, signalBadPingMs);
	final double load =
			_grade(loadPercent, signalGoodLoadPercent, signalBadLoadPercent);
	final double score = ping * signalPingWeight + load * signalLoadWeight;

	// Either dimension being bad on its own costs bars: a node with a 20 ms
	// round trip that is 92% full is not a three-bar server, and averaging would
	// let the good half hide the bad one.
	final double weakest = math.min(ping, load);
	if (weakest < 0.18) return SignalStrength.weak;

	if (score >= 0.66 && weakest >= 0.40) {
		return pingMs == null ? SignalStrength.fair : SignalStrength.strong;
	}
	if (score >= 0.36) return SignalStrength.fair;
	return SignalStrength.weak;
}
