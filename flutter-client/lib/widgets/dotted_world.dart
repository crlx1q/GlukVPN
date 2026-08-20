import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/world_map_data.dart';
import '../theme/tokens.dart';
import '../utils/geo.dart';

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
		this.zoom = 1,
		this.focus = const Offset(0.5, 0.5),
		this.dotOpacity = 0.5,
		this.selfPoint,
		this.serverPoint,
		this.nodePoints = const <MapPoint>[],
		this.arcProgress = 0,
		this.arcPhase = 0,
		this.orbitalPhase = 0,
		this.pulse = 0,
		this.connected = false,
	});

	/// 0 = flat map, 1 = globe.
	final double globeness;

	/// Rotation applied to the globe (and, proportionally, to the morphing map).
	final double rotationDegrees;

	/// 1 fits the map's width to the widget; larger values zoom in.
	final double zoom;

	/// Which point of the map sits at the centre, in 0..1 map fractions.
	/// The mockup's home screen uses `object-position: 60% 30%`.
	final Offset focus;

	/// `.map-img { opacity: 0.5 }` in the mockup.
	final double dotOpacity;

	/// The user's approximate position, if known.
	final MapPoint? selfPoint;

	/// The selected node's position.
	final MapPoint? serverPoint;

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
					zoom: zoom,
					focus: focus,
					dotOpacity: dotOpacity,
					selfPoint: selfPoint,
					serverPoint: serverPoint,
					nodePoints: nodePoints,
					arcProgress: arcProgress.clamp(0.0, 1.0),
					arcPhase: arcPhase,
					orbitalPhase: orbitalPhase,
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
		required this.zoom,
		required this.focus,
		required this.dotOpacity,
		required this.selfPoint,
		required this.serverPoint,
		required this.nodePoints,
		required this.arcProgress,
		required this.arcPhase,
		required this.orbitalPhase,
		required this.pulse,
		required this.connected,
	});

	final double globeness;
	final double rotationDegrees;
	final double zoom;
	final Offset focus;
	final double dotOpacity;
	final MapPoint? selfPoint;
	final MapPoint? serverPoint;
	final List<MapPoint> nodePoints;
	final double arcProgress;
	final double arcPhase;
	final double orbitalPhase;
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
		final globeCentre = Offset(size.width * 0.5, size.height * 0.5);

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

		// Light threads sweeping around the scene. Two thin ellipses with a short
		// bright segment travelling along each, the same idea as the rings around
		// the connect button - which is why they are drawn with one stroke each
		// and no glow stack: subtle, not busy.
		if (orbitalPhase > 0) {
			_paintOrbitals(canvas, size, globeCentre, globeRadius);
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

		// Markers and arc are only meaningful on (or near) the flat map.
		final markerFade = 1 - globeness;
		if (markerFade <= 0.01) return;

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
					)?.offset;
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
					)?.offset;

		final accent = connected ? GlukColors.connected : GlukColors.violetLight;

		if (self != null && server != null && arcProgress > 0) {
			_paintArc(
				canvas,
				from: self,
				to: server,
				arc: ConnectionArc(from: selfPoint!, to: serverPoint!),
				flatScale: flatScale,
				flatCentre: centre,
				globeRadius: globeRadius,
				globeCentre: globeCentre,
				size: size,
				opacity: markerFade,
				accent: accent,
			);
		}

		if (self != null) {
			_paintMarker(canvas, self, GlukColors.violetLight, markerFade, flatScale);
		}
		if (server != null) {
			_paintMarker(canvas, server, accent, markerFade, flatScale, pulsing: true);
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

		// Rotation only makes sense once we are (partly) a globe.
		final spin = rotationDegrees * globeness;

		// --- flat ---
		final wrappedX = ((dot.x + spin / 360 * mapWidth) % mapWidth + mapWidth) % mapWidth;
		final flat = Offset(
			flatCentre.dx + (wrappedX - mapWidth / 2) * flatScale,
			flatCentre.dy + (dot.y - mapHeight / 2) * flatScale,
		);

		if (globeness <= 0) {
			if (cull && !_inside(flat, size)) return null;
			return (offset: flat, visibility: 1);
		}

		// --- globe (orthographic) ---
		final phi = lat * math.pi / 180;
		final lambda = (lon + spin) * math.pi / 180;
		final cosPhi = math.cos(phi);
		final x3 = cosPhi * math.sin(lambda);
		final y3 = -math.sin(phi);
		final z3 = cosPhi * math.cos(lambda);
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

		final path = Path()
			..moveTo(from.dx, from.dy)
			..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);

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
				to,
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

	/// Two tilted ellipses with a light running along them.
	void _paintOrbitals(Canvas canvas, Size size, Offset globeCentre, double radius) {
		// On the flat map there is no sphere to orbit, so the threads are anchored
		// to the upper third of the scene, where the composition's mass is.
		final anchor = Offset.lerp(
			Offset(size.width * 0.5, size.height * 0.30),
			globeCentre,
			globeness,
		)!;
		final base = math.max(size.shortestSide * 0.36, radius * 1.18);

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
					..color = GlukColors.violetLight.withOpacity(0.09),
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
				..color = GlukColors.violetLight.withOpacity(0.38);
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
			old.pulse != pulse ||
			!_sameFleet(old.nodePoints, nodePoints) ||
			old.connected != connected;
}
