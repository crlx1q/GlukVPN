import 'dart:math' as math;

import 'geo.dart';

/// The little world that plays behind onboarding: people in a dozen places,
/// a handful of exit nodes, and threads that come up, live for a while and drop
/// again.
///
/// The mock-up only draws one person and one server because it is a still
/// picture. On a screen that stays in front of someone for half a minute the
/// point is different - it should read as "a network with traffic on it", so
/// several links are always in flight and each one is at a different stage of
/// its life.
///
/// Everything is a pure function of time from a fixed table: no `Random`, no
/// state, nothing to reset. That is what keeps the scene from ever "twitching"
/// back to a starting pose, and it is what makes it testable.
class ShowcaseWorld {
	const ShowcaseWorld._();

	static const ShowcaseWorld standard = ShowcaseWorld._();

	/// Exit nodes. Frankfurt is first: it is the node the app actually ships
	/// with, so the scene and the server list agree with each other.
	static const List<({double lat, double lon})> _hubs = <({double lat, double lon})>[
		(lat: 50.11, lon: 8.68), // Frankfurt
		(lat: 52.37, lon: 4.90), // Amsterdam
		(lat: 40.71, lon: -74.01), // New York
		(lat: 1.35, lon: 103.82), // Singapore
		(lat: -23.55, lon: -46.63), // Sao Paulo
	];

	/// People. Spread over both hemispheres so the scene works at any camera
	/// position, and none of them sits on top of a hub.
	static const List<({double lat, double lon})> _peers = <({double lat, double lon})>[
		(lat: 51.13, lon: 71.43), // Astana
		(lat: 41.01, lon: 28.98), // Istanbul
		(lat: 51.51, lon: -0.13), // London
		(lat: 40.42, lon: -3.70), // Madrid
		(lat: 28.61, lon: 77.21), // Delhi
		(lat: 35.69, lon: 139.69), // Tokyo
		(lat: -33.87, lon: 151.21), // Sydney
		(lat: -26.20, lon: 28.05), // Johannesburg
		(lat: 19.43, lon: -99.13), // Mexico City
		(lat: 45.42, lon: -75.70), // Ottawa
		(lat: 55.68, lon: 12.57), // Copenhagen
		(lat: -34.60, lon: -58.38), // Buenos Aires
	];

	/// Seconds per cycle and where in that cycle each peer starts. The periods
	/// are deliberately co-prime-ish and the offsets spread across the whole
	/// range, so links never all breathe together and there is no moment with
	/// nothing on the map.
	static const List<({double period, double offset})> _rhythm =
			<({double period, double offset})>[
		(period: 13.0, offset: 0.00),
		(period: 17.0, offset: 0.31),
		(period: 11.0, offset: 0.62),
		(period: 19.0, offset: 0.13),
		(period: 14.0, offset: 0.47),
		(period: 23.0, offset: 0.78),
		(period: 16.0, offset: 0.22),
		(period: 21.0, offset: 0.55),
		(period: 12.0, offset: 0.86),
		(period: 18.0, offset: 0.38),
		(period: 15.0, offset: 0.70),
		(period: 20.0, offset: 0.05),
	];

	/// Where the exit nodes are drawn, in map space.
	List<MapPoint> get hubs => <MapPoint>[
		for (final ({double lat, double lon}) hub in _hubs)
			projectLatLon(hub.lat, hub.lon),
	];

	/// Where the people are drawn, in map space.
	List<MapPoint> get peers => <MapPoint>[
		for (final ({double lat, double lon}) peer in _peers)
			projectLatLon(peer.lat, peer.lon),
	];

	int get peerCount => _peers.length;
	int get hubCount => _hubs.length;

	/// Which hub a peer is talking to during a given cycle. Changing hubs
	/// between cycles is what makes the scene read as "connecting somewhere
	/// else" rather than one fixed wiring diagram blinking on and off.
	int hubForCycle(int peer, int cycle) => (peer + cycle * 2 + 1) % _hubs.length;

	/// Every link that is currently drawn, at [seconds] into the scene.
	List<ShowcaseThread> threadsAt(double seconds) {
		final List<MapPoint> hubPoints = hubs;
		final List<MapPoint> peerPoints = peers;
		final List<ShowcaseThread> threads = <ShowcaseThread>[];

		for (int i = 0; i < peerPoints.length; i++) {
			final ({double period, double offset}) rhythm =
					_rhythm[i % _rhythm.length];
			final double raw = seconds / rhythm.period + rhythm.offset;
			final int cycle = raw.floor();
			final double u = raw - cycle;

			final _Stage stage = _stageAt(u);
			if (stage.opacity <= 0) continue;

			threads.add(ShowcaseThread(
				peer: i,
				hub: hubForCycle(i, cycle),
				from: peerPoints[i],
				to: hubPoints[hubForCycle(i, cycle)],
				progress: stage.progress,
				opacity: stage.opacity,
				settled: stage.settled,
				// A phase per link, so the light on each thread travels
				// independently instead of the whole map pulsing in step.
				phase: (raw * 1.7 + i * 0.37) % 1.0,
			));
		}
		return threads;
	}

	/// How many links are live at [seconds]. Used by tests to prove the scene is
	/// never empty and never completely full.
	int activeAt(double seconds) => threadsAt(seconds).length;

	/// A link's life, in fractions of its own cycle:
	///
	///   0.00 - 0.14  reaching out (the thread draws itself in)
	///   0.14 - 0.66  established
	///   0.66 - 0.80  letting go (fades, without un-drawing)
	///   0.80 - 1.00  idle
	_Stage _stageAt(double u) {
		if (u < 0.14) {
			final double t = u / 0.14;
			// ease-out, so a thread arrives quickly and settles.
			final double eased = 1 - math.pow(1 - t, 3).toDouble();
			return _Stage(progress: eased, opacity: math.min(1, t * 1.6), settled: false);
		}
		if (u < 0.66) {
			return const _Stage(progress: 1, opacity: 1, settled: true);
		}
		if (u < 0.80) {
			final double t = (u - 0.66) / 0.14;
			return _Stage(progress: 1, opacity: 1 - t, settled: false);
		}
		return const _Stage(progress: 1, opacity: 0, settled: false);
	}
}

class _Stage {
	const _Stage({
		required this.progress,
		required this.opacity,
		required this.settled,
	});

	final double progress;
	final double opacity;
	final bool settled;
}

/// One link between a person and an exit node at a moment in time.
class ShowcaseThread {
	const ShowcaseThread({
		required this.peer,
		required this.hub,
		required this.from,
		required this.to,
		required this.progress,
		required this.opacity,
		required this.settled,
		required this.phase,
	});

	final int peer;
	final int hub;
	final MapPoint from;
	final MapPoint to;

	/// 0..1 - how much of the thread is drawn.
	final double progress;

	/// 0..1 - master opacity for the whole link.
	final double opacity;

	/// True while the link is established, which is when its endpoints glow.
	final bool settled;

	/// 0..1 - travel of the light along the thread.
	final double phase;
}
