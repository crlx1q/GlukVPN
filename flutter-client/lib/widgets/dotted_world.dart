import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/world_map_data.dart';
import '../theme/tokens.dart';
import '../utils/geo.dart';
import '../utils/showcase.dart';

/// The dotted world from the mockup, drawn as points rather than an SVG.
///
/// The mockup ships a 200 KB SVG with 3065 `<circle>` elements. Parsing that on
/// every frame would be wasteful, so the same 3065 dots live in a 2 KB bitmask
/// ([worldMapDots]) and are painted directly. Identical output, no dependency,
/// and cheap enough to animate.
///
/// One painter covers both the onboarding planet and the home-screen map:
/// [globeness] morphs continuously between the flat equirectangular map (0) and
/// an orthographic globe (1). That is what makes the "planet zooms into the
/// map" transition possible - it is one widget changing a single number, not two
/// different screens crossfading.
class DottedWorld extends StatelessWidget {
	const DottedWorld({
		super.key,
		this.globeness = 0,
		this.rotationDegrees = 0,
		this.centreLongitude = 0,
		this.centreLatitude = 0,
		this.globeAnchor = const Offset(0.5, 0.5),
		this.driftDegrees = 0,
		this.zoom = 1,
		this.focus = const Offset(0.5, 0.5),
		this.dotOpacity = 0.5,
		this.selfPoint,
		this.selfOpacity = 1,
		this.serverPoint,
		this.serverOpacity = 1,
		this.nodePoints = const <MapPoint>[],
		this.arcProgress = 0,
		this.arcPhase = 0,
		this.orbitalPhase = 0,
		this.orbitalAnchor = const Offset(0.5, 0.30),
		this.orbitalRadius,
		this.showcase = 0,
		this.showcaseSeconds = 0,
		this.pulse = 0,
		this.connected = false,
	});

	/// 0 = flat map, 1 = globe.
	final double globeness;

	/// Rotation applied to the globe (and, proportionally, to the morphing map).
	final double rotationDegrees;

	/// The longitude the camera is looking at: the meridian that ends up in the
	/// middle of the sphere. Flying from one place to another is a change of this
	/// value, which is a camera move rather than a zoom.
	final double centreLongitude;

	/// The latitude the camera is looking at. The sphere is tilted about its X
	/// axis by this much, so a point at ([centreLongitude], [centreLatitude])
	/// lands exactly at the middle of the globe.
	final double centreLatitude;

	/// Where the middle of the sphere sits on the canvas, in 0..1 fractions.
	/// The default is the centre; onboarding's last frame pushes it left so the
	/// planet runs off the screen and only its right half is visible.
	final Offset globeAnchor;

	/// A slow horizontal drift for the flat map, in degrees of longitude, so the
	/// home screen's world is never completely still.
	final double driftDegrees;

	/// 1 fits the map's width to the widget; larger values zoom in.
	final double zoom;

	/// Which point of the map sits at the centre, in 0..1 map fractions.
	/// The mockup's home screen uses `object-position: 60% 30%`.
	final Offset focus;

	/// `.map-img { opacity: 0.5 }` in the mockup.
	final double dotOpacity;

	/// The user's approximate position, if known.
	final MapPoint? selfPoint;

	/// Fades the user's marker in without moving it.
	final double selfOpacity;

	/// The selected node's position.
	final MapPoint? serverPoint;

	/// Fades the node's marker in without moving it.
	final double serverOpacity;

	/// Every node that is currently online, drawn as a small green point with
	/// hair-thin links between them. These come from `GET /api/nodes`, so the
	/// constellation is the real fleet rather than decoration.
	final List<MapPoint> nodePoints;

	/// 0..1 - how much of the connection arc to draw.
	final double arcProgress;

	/// 0..1 - marching-dash offset (`dashFlow` in the mockup).
	final double arcPhase;

	/// 0..1 - travel of the light along the orbital threads.
	final double orbitalPhase;

	/// Where the orbital threads are centred on the **flat** map, in fractions
	/// of the paint size. Ignored as [globeness] reaches 1, where the planet's
	/// own centre takes over.
	///
	/// The default keeps them in the upper third, which is what the phone's
	/// composition wants. The desktop map card overrides it to the middle so the
	/// ribbons ring the power button instead of flying above it.
	final Offset orbitalAnchor;

	/// Radius of the outer thread on the flat map, in pixels. Null sizes it from
	/// the viewport, which is right when the threads decorate the whole scene and
	/// wrong when they are meant to hug one specific control.
	final double? orbitalRadius;

	/// 0..1 - how strongly the showcase scene is drawn: people scattered over the
	/// world, exit nodes, and threads that come up and drop again.
	///
	/// Onboarding and sign-in run it; the home screen leaves it at 0, because
	/// there the map is about *your* connection and inventing traffic on it would
	/// be a lie.
	final double showcase;

	/// Seconds into that scene. It only ever moves forward, which is what keeps
	/// the world from jumping back to a starting pose.
	final double showcaseSeconds;

	/// 0..1 - shared phase for the expanding rings under the two markers.
	final double pulse;

	/// Tints the arc and the server marker soft green once the tunnel is up.
	final bool connected;

	@override
	Widget build(BuildContext context) {
		return RepaintBoundary(
			child: CustomPaint(
				painter: _DottedWorldPainter(
					globeness: globeness.clamp(0.0, 1.0),
					rotationDegrees: rotationDegrees,
					centreLongitude: centreLongitude,
					centreLatitude: centreLatitude,
					globeAnchor: globeAnchor,
					driftDegrees: driftDegrees,
					zoom: zoom,
					focus: focus,
					dotOpacity: dotOpacity,
					selfPoint: selfPoint,
					selfOpacity: selfOpacity.clamp(0.0, 1.0),
					serverPoint: serverPoint,
					serverOpacity: serverOpacity.clamp(0.0, 1.0),
					nodePoints: nodePoints,
					arcProgress: arcProgress.clamp(0.0, 1.0),
					arcPhase: arcPhase,
					orbitalPhase: orbitalPhase,
					orbitalAnchor: orbitalAnchor,
					orbitalRadius: orbitalRadius,
					showcase: showcase.clamp(0.0, 1.0),
					showcaseSeconds: showcaseSeconds,
					pulse: pulse,
					connected: connected,
				),
				size: Size.infinite,
			),
		);
	}
}

class _DottedWorldPainter extends CustomPainter {
	_DottedWorldPainter({
		required this.globeness,
		required this.rotationDegrees,
		required this.centreLongitude,
		required this.centreLatitude,
		required this.globeAnchor,
		required this.driftDegrees,
		required this.zoom,
		required this.focus,
		required this.dotOpacity,
		required this.selfPoint,
		required this.selfOpacity,
		required this.serverPoint,
		required this.serverOpacity,
		required this.nodePoints,
		required this.arcProgress,
		required this.arcPhase,
		required this.orbitalPhase,
		required this.orbitalAnchor,
		required this.orbitalRadius,
		required this.showcase,
		required this.showcaseSeconds,
		required this.pulse,
		required this.connected,
	});

	final double globeness;
	final double rotationDegrees;
	final double centreLongitude;
	final double centreLatitude;
	final Offset globeAnchor;
	final double driftDegrees;
	final double zoom;
	final Offset focus;
	final double dotOpacity;
	final MapPoint? selfPoint;
	final double selfOpacity;
	final MapPoint? serverPoint;
	final double serverOpacity;
	final List<MapPoint> nodePoints;
	final double arcProgress;
	final double arcPhase;
	final double orbitalPhase;
	final Offset orbitalAnchor;
	final double? orbitalRadius;
	final double showcase;
	final double showcaseSeconds;
	final double pulse;
	final bool connected;

	/// Dots are bucketed by opacity so the whole map is drawn with a handful of
	/// `drawPoints` calls instead of 3065 `drawCircle` calls.
	static const _buckets = 5;

	@override
	void paint(Canvas canvas, Size size) {
		if (size.isEmpty) return;

		// Flat map scale: `zoom == 1` means the map's full width fits the widget.
		final flatScale = size.width / mapWidth * zoom;
		// Globe radius: the sphere's diameter is the map's width divided by pi
		// (a full turn of longitude wrapped onto a circle), which keeps dot
		// density roughly constant through the morph.
		final globeRadius = size.width * zoom / math.pi / 2;

		final centre = Offset(
			size.width * 0.5 + (0.5 - focus.dx) * mapWidth * flatScale,
			size.height * 0.5 + (0.5 - focus.dy) * mapHeight * flatScale,
		);
		// The sphere does not have to sit in the middle of the canvas: the last
		// onboarding frame pushes it left, off the screen, on purpose.
		final globeCentre = Offset(
			size.width * globeAnchor.dx,
			size.height * globeAnchor.dy,
		);

		final dotRadius = math.max(0.55, 0.4 * flatScale);

		final buckets = List.generate(_buckets, (_) => <Offset>[]);

		for (final dot in worldMapDots) {
			final projected = _project(
				dot,
				flatScale: flatScale,
				flatCentre: centre,
				globeRadius: globeRadius,
				globeCentre: globeCentre,
				size: size,
			);
			if (projected == null) continue;
			final bucket = (projected.visibility * (_buckets - 1)).round();
			buckets[bucket].add(projected.offset);
		}

		for (var i = 0; i < _buckets; i++) {
			final points = buckets[i];
			if (points.isEmpty) continue;
			final fraction = i / (_buckets - 1);
			final paint = Paint()
				..color = GlukColors.mapDot.withOpacity(dotOpacity * fraction)
				..strokeWidth = dotRadius * 2
				..strokeCap = StrokeCap.round
				..isAntiAlias = true;
			canvas.drawPoints(ui.PointMode.points, points, paint);
		}

		// Sphere shading: the mockup's `.globe::before` / `.globe::after` inset
		// gradients. This is what turns a field of dots into a lit ball instead of
		// a flat sticker, and it costs three draw calls.
		if (globeness > 0.02) {
			_paintGlobeShading(canvas, globeCentre, globeRadius);
		}

		// Light threads sweeping around the scene. Two thin ellipses with a short
		// bright segment travelling along each, the same idea as the rings around
		// the connect button - which is why they are drawn with one stroke each
		// and no glow stack: subtle, not busy.
		if (orbitalPhase > 0) {
			_paintOrbitals(canvas, size, globeCentre, globeRadius);
		}

		// The showcase scene: a dozen people, five exit nodes, and threads that
		// come up and drop again. Drawn under the user's own markers, so their
		// route stays the subject of the picture rather than one line in a crowd.
		if (showcase > 0.01) {
			_paintShowcase(
				canvas,
				size,
				flatScale: flatScale,
				flatCentre: centre,
				globeRadius: globeRadius,
				globeCentre: globeCentre,
			);
		}

		// The live fleet: one green point per online node, linked by hair-thin
		// lines so the map reads as a network instead of wallpaper.
		if (nodePoints.isNotEmpty) {
			final fleet = <Offset>[];
			for (final point in nodePoints) {
				final projected = _project(
					point,
					flatScale: flatScale,
					flatCentre: centre,
					globeRadius: globeRadius,
					globeCentre: globeCentre,
					size: size,
				);
				if (projected == null || projected.visibility <= 0.08) continue;
				fleet.add(projected.offset);
			}
			_paintFleet(canvas, size, fleet, flatScale);
		}

		// Markers and the thread between them are drawn on the globe as well as on
		// the flat map: the onboarding camera flies to the user's dot and then on
		// to the node, so hiding them while globeness > 0 would remove the whole
		// point of the scene.
		final self = selfPoint == null
				? null
				: _project(
						selfPoint!,
						flatScale: flatScale,
						flatCentre: centre,
						globeRadius: globeRadius,
						globeCentre: globeCentre,
						size: size,
						cull: false,
					);
		final server = serverPoint == null
				? null
				: _project(
						serverPoint!,
						flatScale: flatScale,
						flatCentre: centre,
						globeRadius: globeRadius,
						globeCentre: globeCentre,
						size: size,
						cull: false,
					);

		// A place on the far side of the sphere must not shine through it, so a
		// marker's opacity follows how much of it faces the camera.
		double facing(({Offset offset, double visibility})? projected) {
			if (projected == null) return 0;
			return ui.lerpDouble(1, projected.visibility.clamp(0.0, 1.0), globeness)!;
		}

		final selfFade = facing(self) * selfOpacity;
		final serverFade = facing(server) * serverOpacity;
		final accent = connected ? GlukColors.connected : GlukColors.violetLight;

		if (self != null && server != null && arcProgress > 0) {
			final routeFade = math.min(selfFade, serverFade);
			if (routeFade > 0.02) {
				_paintArc(
					canvas,
					from: self.offset,
					to: server.offset,
					arc: ConnectionArc(from: selfPoint!, to: serverPoint!),
					flatScale: flatScale,
					flatCentre: centre,
					globeRadius: globeRadius,
					globeCentre: globeCentre,
					size: size,
					opacity: routeFade,
					accent: accent,
				);
			}
		}

		if (self != null && selfFade > 0.02) {
			_paintMarker(
				canvas,
				self.offset,
				GlukColors.violetLight,
				selfFade,
				flatScale,
				pulsing: true,
			);
		}
		if (server != null && serverFade > 0.02) {
			_paintMarker(
				canvas,
				server.offset,
				accent,
				serverFade,
				flatScale,
				pulsing: true,
			);
		}
	}

	/// Projects a map-space point to the canvas, morphing between the flat map
	/// and the globe. Returns null when the dot is culled.
	({Offset offset, double visibility})? _project(
		MapPoint dot, {
		required double flatScale,
		required Offset flatCentre,
		required double globeRadius,
		required Offset globeCentre,
		required Size size,
		bool cull = true,
	}) {
		// Map space -> geographic.
		final lat = 90 - dot.y / mapHeight * 180;
		final lon = dot.x / mapWidth * 360 - 180;

		// Where the camera is pointing. Subtracting the centre longitude is what
		// brings a chosen meridian to the middle of the sphere; the tilt does the
		// same for latitude.
		final spin = (rotationDegrees - centreLongitude) * globeness;
		final tilt = centreLatitude * globeness * math.pi / 180;

		// --- flat ---
		// `driftDegrees` only applies to the flat map, where there is no sphere to
		// rotate but the world should still breathe.
		final shift = (spin + driftDegrees * (1 - globeness)) / 360 * mapWidth;
		final wrappedX = ((dot.x + shift) % mapWidth + mapWidth) % mapWidth;
		final flat = Offset(
			flatCentre.dx + (wrappedX - mapWidth / 2) * flatScale,
			flatCentre.dy + (dot.y - mapHeight / 2) * flatScale,
		);

		if (globeness <= 0) {
			if (cull && !_inside(flat, size)) return null;
			return (offset: flat, visibility: 1);
		}

		// --- globe (orthographic, camera tilted to a latitude) ---
		final phi = lat * math.pi / 180;
		final lambda = (lon + spin) * math.pi / 180;
		final cosPhi = math.cos(phi);
		final x3 = cosPhi * math.sin(lambda);
		// North-positive vertical and depth, rotated about the X axis by `tilt`,
		// so a point at (centreLongitude, centreLatitude) lands dead centre.
		final north = math.sin(phi);
		final front = cosPhi * math.cos(lambda);
		final y3 = -(north * math.cos(tilt) - front * math.sin(tilt));
		final z3 = north * math.sin(tilt) + front * math.cos(tilt);
		final globe = Offset(
			globeCentre.dx + x3 * globeRadius,
			globeCentre.dy + y3 * globeRadius,
		);

		// Soft edge instead of a hard cut, so dots fade over the horizon.
		final farSide = ((z3 + 0.12) / 0.24).clamp(0.0, 1.0);
		final visibility = ui.lerpDouble(1, farSide, globeness)!;

		final offset = Offset(
			ui.lerpDouble(flat.dx, globe.dx, globeness)!,
			ui.lerpDouble(flat.dy, globe.dy, globeness)!,
		);

		if (cull && (visibility <= 0.02 || !_inside(offset, size))) return null;
		return (offset: offset, visibility: visibility);
	}

	bool _inside(Offset offset, Size size) {
		const margin = 8.0;
		return offset.dx >= -margin &&
				offset.dy >= -margin &&
				offset.dx <= size.width + margin &&
				offset.dy <= size.height + margin;
	}

	/// `.conn-path`: a quadratic bow, 0.55 map-units wide, drawn with a marching
	/// `1.6 / 1.4` dash pattern.
	void _paintArc(
		Canvas canvas, {
		required Offset from,
		required Offset to,
		required ConnectionArc arc,
		required double flatScale,
		required Offset flatCentre,
		required double globeRadius,
		required Offset globeCentre,
		required Size size,
		required double opacity,
		required Color accent,
	}) {
		final control = _project(
			arc.control,
			flatScale: flatScale,
			flatCentre: flatCentre,
			globeRadius: globeRadius,
			globeCentre: globeCentre,
			size: size,
			cull: false,
		)?.offset;
		if (control == null) return;

		// Both ends and the bend are pulled onto the same side of the map's seam,
		// so a route never gets drawn the long way round on the scrolling map.
		final target = _alignFlat(from, to, flatScale);
		final bend = _alignFlat(from, control, flatScale);

		final path = Path()
			..moveTo(from.dx, from.dy)
			..quadraticBezierTo(bend.dx, bend.dy, target.dx, target.dy);

		final strokeWidth = math.max(1.2, 0.55 * flatScale);
		final dash = math.max(3.0, 1.6 * flatScale);
		final gap = math.max(2.6, 1.4 * flatScale);

		final paint = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = strokeWidth
			..strokeCap = StrokeCap.round
			..isAntiAlias = true
			..shader = ui.Gradient.linear(
				from,
				target,
				[
					accent.withOpacity(0.95 * opacity),
					(connected ? GlukColors.connected : GlukColors.blue)
							.withOpacity(0.95 * opacity),
				],
			);

		canvas.drawPath(
			_dashed(path, dash: dash, gap: gap, phase: arcPhase * (dash + gap), progress: arcProgress),
			paint,
		);
	}

	/// `.globe::before` / `.globe::after`: a violet highlight at 32% / 26%, a
	/// deep shadow at 70% / 78%, and the blue rim glow inside the limb
	/// (`inset 0 0 26px 6px rgba(79,124,255,0.35)`).
	void _paintGlobeShading(Canvas canvas, Offset centre, double radius) {
		final rect = Rect.fromCircle(center: centre, radius: radius);
		final k = globeness.clamp(0.0, 1.0);

		canvas.drawCircle(
			centre,
			radius,
			Paint()
				..shader = ui.Gradient.radial(
					Offset(rect.left + rect.width * 0.32, rect.top + rect.height * 0.26),
					radius * 0.95,
					<Color>[
						const Color(0xFFB4A5FF).withOpacity(0.15 * k),
						const Color(0x00B4A5FF),
					],
					<double>[0, 1],
				),
		);

		canvas.drawCircle(
			centre,
			radius,
			Paint()
				..shader = ui.Gradient.radial(
					Offset(rect.left + rect.width * 0.70, rect.top + rect.height * 0.78),
					radius * 1.05,
					<Color>[
						Colors.black.withOpacity(0.42 * k),
						const Color(0x00000000),
					],
					<double>[0, 1],
				),
		);

		canvas.drawCircle(
			centre,
			radius * 0.97,
			Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = radius * 0.10
				..isAntiAlias = true
				..color = GlukColors.blue.withOpacity(0.20 * k)
				..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.09),
		);
	}

	/// Two tilted ellipses with a light running along them.
	///
	/// The radius is the *planet's*, not the screen's. It used to be
	/// `max(shortestSide * 0.36, radius * 1.18)`, which meant the rings were
	/// sized by the viewport whenever the globe was small: they swamped the
	/// planet on the first onboarding frame and looked like a tiny bracelet by
	/// the third. Tying them to the globe keeps the same relationship at every
	/// camera distance, which is the whole point of orbits.
	void _paintOrbitals(Canvas canvas, Size size, Offset globeCentre, double radius) {
		// On the flat map there is no sphere to orbit, so the threads follow
		// [orbitalAnchor]. This used to be hard-coded to the upper third, which is
		// right on the phone but wrong on the desktop map card, where the power
		// button sits dead centre: the ribbons flew above the button instead of
		// around it.
		final anchor = Offset.lerp(
			Offset(size.width * orbitalAnchor.dx, size.height * orbitalAnchor.dy),
			globeCentre,
			globeness,
		)!;
		// Sizing from the viewport only makes sense while the threads decorate the
		// whole scene. When they are meant to hug a control, that control's radius
		// is the only number that keeps the relationship stable as the window
		// changes shape.
		final flatBase = orbitalRadius ?? size.shortestSide * 0.36;
		final base = ui.lerpDouble(flatBase, radius * 1.16, globeness)!;

		// Once the planet is wider than the screen its orbits are off-canvas, and
		// all that is left on screen are two arcs cutting across the corners. Fade
		// them out instead.
		final fade = ((size.shortestSide * 0.62) / math.max(base, 1.0)).clamp(0.0, 1.0);
		if (fade <= 0.02) return;

		for (var i = 0; i < 2; i++) {
			final rx = base * (i == 0 ? 1.0 : 0.74);
			final ry = rx * (i == 0 ? 0.30 : 0.21);
			canvas.save();
			canvas.translate(anchor.dx, anchor.dy);
			canvas.rotate(i == 0 ? -0.26 : 0.33);

			final path = Path()
				..addOval(Rect.fromCenter(
					center: Offset.zero,
					width: rx * 2,
					height: ry * 2,
				));

			canvas.drawPath(
				path,
				Paint()
					..style = PaintingStyle.stroke
					..strokeWidth = 0.9
					..isAntiAlias = true
					..color = GlukColors.violetLight.withOpacity(0.09 * fade),
			);

			final metric = path.computeMetrics().first;
			final length = metric.length;
			final head = ((orbitalPhase + i * 0.45) % 1.0) * length;
			final tail = head - length * 0.15;
			final glow = Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = 1.5
				..strokeCap = StrokeCap.round
				..isAntiAlias = true
				..color = GlukColors.violetLight.withOpacity(0.38 * fade);
			// Wrap around the seam instead of blinking out at the top of the loop.
			if (tail < 0) {
				canvas.drawPath(metric.extractPath(0, head), glow);
				canvas.drawPath(metric.extractPath(length + tail, length), glow);
			} else {
				canvas.drawPath(metric.extractPath(tail, head), glow);
			}
			canvas.restore();
		}
	}

	/// The flat map repeats every 360 degrees, so two places can be projected a
	/// whole world apart inside the same picture - and a route from Astana to
	/// Frankfurt would then be drawn the long way round, straight across the
	/// screen. This nudges [point] by whole map widths until it sits on the same
	/// side of the seam as [anchor], which is what lets the map scroll for ever
	/// without any line noticing.
	Offset _alignFlat(Offset anchor, Offset point, double flatScale) {
		if (globeness >= 0.5) return point;
		final period = mapWidth * flatScale;
		if (period <= 0) return point;
		final raw = point.dx - anchor.dx;
		final dx = raw - period * (raw / period).roundToDouble();
		return Offset(anchor.dx + dx, point.dy);
	}

	/// The showcase scene.
	///
	/// Deliberately not a copy of the mock-up's single dot-and-thread: that is a
	/// still picture, and this screen is watched for half a minute. Several links
	/// are always in flight, each at a different point in its own life, so the
	/// map reads as a network with traffic on it - and because every link's
	/// timing comes from a fixed table, nothing ever resets to a starting pose.
	void _paintShowcase(
		Canvas canvas,
		Size size, {
		required double flatScale,
		required Offset flatCentre,
		required double globeRadius,
		required Offset globeCentre,
	}) {
		final master = showcase.clamp(0.0, 1.0);
		final world = ShowcaseWorld.standard;

		({Offset offset, double visibility})? place(MapPoint point) => _project(
			point,
			flatScale: flatScale,
			flatCentre: flatCentre,
			globeRadius: globeRadius,
			globeCentre: globeCentre,
			size: size,
			cull: false,
		);

		final peers = world.peers
				.map<({Offset offset, double visibility})?>(place)
				.toList(growable: false);
		final hubs = world.hubs
				.map<({Offset offset, double visibility})?>(place)
				.toList(growable: false);

		double facing(({Offset offset, double visibility})? projected) {
			if (projected == null) return 0;
			return ui.lerpDouble(1, projected.visibility.clamp(0.0, 1.0), globeness)!;
		}

		final livePeers = <int>{};
		final liveHubs = <int>{};

		for (final thread in world.threadsAt(showcaseSeconds)) {
			final peer = peers[thread.peer];
			final hub = hubs[thread.hub];
			if (peer == null || hub == null) continue;
			final fade =
					math.min(facing(peer), facing(hub)) * thread.opacity * master;
			if (fade <= 0.03) continue;

			livePeers.add(thread.peer);
			liveHubs.add(thread.hub);

			final from = peer.offset;
			final to = _alignFlat(from, hub.offset, flatScale);
			final span = to - from;
			final length = span.distance;
			if (length < 0.5) continue;

			// A perpendicular lift, computed in canvas space so the bow is right on
			// the sphere as well as on the flat map, and always away from the
			// surface rather than through it.
			final unit = Offset(span.dy, -span.dx) / length;
			final normal = unit.dy <= 0 ? unit : -unit;
			final control = (from + to) / 2 + normal * (length * 0.16);

			final path = Path()
				..moveTo(from.dx, from.dy)
				..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);
			final metric = path.computeMetrics().first;
			final drawn = metric.length * thread.progress.clamp(0.0, 1.0);
			if (drawn <= 0.5) continue;

			canvas.drawPath(
				metric.extractPath(0, drawn),
				Paint()
					..style = PaintingStyle.stroke
					..strokeWidth = math.max(0.7, 0.20 * flatScale)
					..strokeCap = StrokeCap.round
					..isAntiAlias = true
					..color = GlukColors.violetLight.withOpacity(0.26 * fade),
			);

			// A light travelling towards the node, but only while the link is up:
			// traffic on an established tunnel, not on one still being set up.
			if (thread.settled) {
				final head = (thread.phase % 1.0) * drawn;
				final tail = math.max(0.0, head - drawn * 0.22);
				if (head - tail > 0.5) {
					canvas.drawPath(
						metric.extractPath(tail, head),
						Paint()
							..style = PaintingStyle.stroke
							..strokeWidth = math.max(1.0, 0.28 * flatScale)
							..strokeCap = StrokeCap.round
							..isAntiAlias = true
							..color = GlukColors.blue.withOpacity(0.50 * fade),
					);
				}
			}
		}

		// People: small violet points, brighter while they hold a link.
		final peerRadius = math.max(1.3, 0.40 * flatScale);
		for (var i = 0; i < peers.length; i++) {
			final peer = peers[i];
			if (peer == null) continue;
			final fade =
					facing(peer) * master * (livePeers.contains(i) ? 1.0 : 0.45);
			if (fade <= 0.03) continue;
			canvas.drawCircle(
				peer.offset,
				peerRadius * 2.4,
				Paint()
					..color = GlukColors.violetLight.withOpacity(0.10 * fade)
					..maskFilter = MaskFilter.blur(BlurStyle.normal, peerRadius * 1.2),
			);
			canvas.drawCircle(
				peer.offset,
				peerRadius,
				Paint()..color = GlukColors.violetLight.withOpacity(0.70 * fade),
			);
		}

		// Exit nodes: green, a size up, with a ring while they are serving.
		final hubRadius = math.max(1.9, 0.58 * flatScale);
		for (var i = 0; i < hubs.length; i++) {
			final hub = hubs[i];
			if (hub == null) continue;
			final live = liveHubs.contains(i);
			final fade = facing(hub) * master * (live ? 1.0 : 0.55);
			if (fade <= 0.03) continue;
			canvas.drawCircle(
				hub.offset,
				hubRadius * 2.8,
				Paint()
					..color = GlukColors.connected.withOpacity(0.16 * fade)
					..maskFilter = MaskFilter.blur(BlurStyle.normal, hubRadius * 1.4),
			);
			canvas.drawCircle(
				hub.offset,
				hubRadius,
				Paint()..color = GlukColors.connected.withOpacity(0.92 * fade),
			);
			if (live && pulse > 0) {
				canvas.drawCircle(
					hub.offset,
					hubRadius * ui.lerpDouble(1.2, 3.0, pulse)!,
					Paint()
						..style = PaintingStyle.stroke
						..strokeWidth = math.max(0.8, 0.16 * flatScale)
						..color =
								GlukColors.connected.withOpacity((1 - pulse) * 0.40 * fade),
				);
			}
		}
	}

	/// Green points for online nodes, with links between neighbours.
	void _paintFleet(Canvas canvas, Size size, List<Offset> fleet, double flatScale) {
		if (fleet.isEmpty) return;
		final reach = size.width * 0.62;
		final link = Paint()
			..style = PaintingStyle.stroke
			..strokeWidth = 0.7
			..isAntiAlias = true
			..color = GlukColors.connected.withOpacity(0.16);

		for (var i = 0; i < fleet.length; i++) {
			for (var j = i + 1; j < fleet.length; j++) {
				if ((fleet[i] - fleet[j]).distance > reach) continue;
				canvas.drawLine(fleet[i], fleet[j], link);
			}
		}

		final dot = math.max(2.0, 0.75 * flatScale);
		for (final point in fleet) {
			canvas.drawCircle(
				point,
				dot * 2.6,
				Paint()
					..color = GlukColors.connected.withOpacity(0.20)
					..maskFilter = MaskFilter.blur(BlurStyle.normal, dot * 1.3),
			);
			canvas.drawCircle(
				point,
				dot,
				Paint()..color = GlukColors.connected.withOpacity(0.9),
			);
		}
	}

	/// A dot with an expanding ring (`mapPulse` in the mockup).
	void _paintMarker(
		Canvas canvas,
		Offset centre,
		Color colour,
		double opacity,
		double flatScale, {
		bool pulsing = false,
	}) {
		final base = math.max(3.0, 1.15 * flatScale);

		if (pulsing && pulse > 0) {
			// scale .5 -> 3.2, fading out, exactly like the CSS keyframe.
			final scale = ui.lerpDouble(0.5, 3.2, pulse)!;
			canvas.drawCircle(
				centre,
				base * scale,
				Paint()
					..style = PaintingStyle.stroke
					..strokeWidth = math.max(1.0, 0.28 * flatScale)
					..color = colour.withOpacity((1 - pulse) * 0.55 * opacity),
			);
		}

		canvas.drawCircle(
			centre,
			base * 2.1,
			Paint()
				..color = colour.withOpacity(0.16 * opacity)
				..maskFilter = MaskFilter.blur(BlurStyle.normal, base),
		);
		canvas.drawCircle(centre, base, Paint()..color = colour.withOpacity(opacity));
		canvas.drawCircle(
			centre,
			base,
			Paint()
				..style = PaintingStyle.stroke
				..strokeWidth = math.max(0.8, 0.16 * flatScale)
				..color = Colors.white.withOpacity(0.55 * opacity),
		);
	}

	/// Turns a path into dashes. `progress` trims the path so the arc can draw
	/// itself in while connecting; `phase` slides the dashes along it.
	Path _dashed(
		Path source, {
		required double dash,
		required double gap,
		required double phase,
		required double progress,
	}) {
		final result = Path();
		final period = dash + gap;
		for (final metric in source.computeMetrics()) {
			final limit = metric.length * progress;
			// Start one period behind so a partially visible dash enters smoothly.
			var distance = -period + (phase % period);
			while (distance < limit) {
				final start = math.max(0.0, distance);
				final end = math.min(distance + dash, limit);
				if (end > start) {
					result.addPath(metric.extractPath(start, end), Offset.zero);
				}
				distance += period;
			}
		}
		return result;
	}

	static bool _sameFleet(List<MapPoint> a, List<MapPoint> b) {
		if (a.length != b.length) return false;
		for (var i = 0; i < a.length; i++) {
			if (a[i].x != b[i].x || a[i].y != b[i].y) return false;
		}
		return true;
	}

	@override
	bool shouldRepaint(_DottedWorldPainter old) =>
			old.globeness != globeness ||
			old.rotationDegrees != rotationDegrees ||
			old.centreLongitude != centreLongitude ||
			old.centreLatitude != centreLatitude ||
			old.globeAnchor != globeAnchor ||
			old.driftDegrees != driftDegrees ||
			old.selfOpacity != selfOpacity ||
			old.serverOpacity != serverOpacity ||
			old.zoom != zoom ||
			old.focus != focus ||
			old.dotOpacity != dotOpacity ||
			old.selfPoint?.x != selfPoint?.x ||
			old.selfPoint?.y != selfPoint?.y ||
			old.serverPoint?.x != serverPoint?.x ||
			old.serverPoint?.y != serverPoint?.y ||
			old.arcProgress != arcProgress ||
			old.arcPhase != arcPhase ||
			old.orbitalPhase != orbitalPhase ||
			old.orbitalAnchor != orbitalAnchor ||
			old.orbitalRadius != orbitalRadius ||
			old.showcase != showcase ||
			old.showcaseSeconds != showcaseSeconds ||
			old.pulse != pulse ||
			!_sameFleet(old.nodePoints, nodePoints) ||
			old.connected != connected;
}
