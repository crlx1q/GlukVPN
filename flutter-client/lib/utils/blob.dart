import 'dart:math' as math;
import 'dart:ui';

/// Geometry for the morphing blobs under the connect button.
///
/// CSS writes a blob as eight radii - `border-radius: a b c d / e f g h`,
/// horizontal set first, each a percentage of the box. Reproducing that with
/// Flutter's [BorderRadius] looks right most of the time and then, on a few
/// frames of the morph, sprouts small spikes at the top corners and along the
/// bottom edge.
///
/// The reason is that the mock-up's keyframes ask for radii that do not fit:
/// `65% + 35%` along one edge is exactly 100%, and the halves either side of a
/// keyframe interpolate to sums slightly above it. CSS handles that case
/// explicitly - it scales *all* radii down by one factor until every edge fits
/// (CSS Backgrounds 3, "Overlapping curves"). An `RRect` instead clamps each
/// corner on its own, so two neighbouring arcs end up meeting at an angle
/// rather than tangentially, and that corner reads as a tiny cross or notch for
/// the frame or two where the sums are over the limit.
///
/// So the shape is built here as an explicit path with CSS's own normalisation:
/// every corner arc starts and ends where the straight part of an edge does, so
/// consecutive segments always share a tangent. The result cannot self-intersect
/// and has no corner to flash - and it is the *same* shape the mock-up draws,
/// not a smoothed-out approximation.
class BlobShape {
	const BlobShape({
		required this.h,
		required this.v,
		this.rotation = 0,
		this.scale = 1,
	});

	/// Horizontal radii as fractions of the width: TL, TR, BR, BL.
	final List<double> h;

	/// Vertical radii as fractions of the height, same order.
	final List<double> v;

	/// Degrees, as in the keyframe's `rotate()`.
	final double rotation;

	/// As in the keyframe's `scale()`.
	final double scale;

	static List<double> _lerpAll(List<double> a, List<double> b, double t) {
		return <double>[
			for (int i = 0; i < 4; i++) a[i] + (b[i] - a[i]) * t,
		];
	}

	static BlobShape lerp(BlobShape a, BlobShape b, double t) => BlobShape(
		h: _lerpAll(a.h, b.h, t),
		v: _lerpAll(a.v, b.v, t),
		rotation: a.rotation + (b.rotation - a.rotation) * t,
		scale: a.scale + (b.scale - a.scale) * t,
	);
}

/// The single factor CSS applies to every radius so that no edge is
/// over-subscribed. 1 means the radii already fit.
///
/// Each edge carries two radii; if their sum exceeds the edge, all eight are
/// scaled by the smallest ratio found. Scaling uniformly is what keeps the
/// silhouette recognisable instead of squashing one corner.
double blobRadiiScale({
	required List<double> h,
	required List<double> v,
	required double width,
	required double height,
}) {
	double factor = 1;

	void consider(double sum, double extent) {
		if (sum <= 0 || extent <= 0) return;
		final double ratio = extent / sum;
		if (ratio < factor) factor = ratio;
	}

	// top and bottom edges spend horizontal radii, left and right vertical ones.
	consider((h[0] + h[1]) * width, width);
	consider((h[3] + h[2]) * width, width);
	consider((v[0] + v[3]) * height, height);
	consider((v[1] + v[2]) * height, height);

	return factor;
}

/// The blob as a closed path inside `size`.
///
/// Corners are elliptical arcs joined by the straight remainder of each edge,
/// exactly like a CSS box. Because [blobRadiiScale] is applied first, those
/// straight parts never have negative length, which is the condition for
/// neighbouring segments to meet smoothly.
Path blobPath({
	required Size size,
	required List<double> h,
	required List<double> v,
}) {
	final double w = size.width;
	final double ht = size.height;
	if (w <= 0 || ht <= 0) return Path();

	final double f = blobRadiiScale(h: h, v: v, width: w, height: ht);

	// A hair of radius on every corner keeps the arcs well-defined; a zero
	// radius would degenerate into a right angle, which is the one shape this
	// blob should never show.
	double hr(int i) => (h[i] * f * w).clamp(0.5, w / 2);
	double vr(int i) => (v[i] * f * ht).clamp(0.5, ht / 2);

	final double h0 = hr(0), h1 = hr(1), h2 = hr(2), h3 = hr(3);
	final double v0 = vr(0), v1 = vr(1), v2 = vr(2), v3 = vr(3);

	return Path()
		..moveTo(h0, 0)
		..lineTo(w - h1, 0)
		..arcToPoint(
			Offset(w, v1),
			radius: Radius.elliptical(h1, v1),
			clockwise: true,
		)
		..lineTo(w, ht - v2)
		..arcToPoint(
			Offset(w - h2, ht),
			radius: Radius.elliptical(h2, v2),
			clockwise: true,
		)
		..lineTo(h3, ht)
		..arcToPoint(
			Offset(0, ht - v3),
			radius: Radius.elliptical(h3, v3),
			clockwise: true,
		)
		..lineTo(0, v0)
		..arcToPoint(
			Offset(h0, 0),
			radius: Radius.elliptical(h0, v0),
			clockwise: true,
		)
		..close();
}

/// Largest distance from the blob's centre to its outline, sampled around the
/// path. Used by tests to prove the silhouette stays inside its box, and by the
/// button to size the layer that sits under it.
double blobReach({
	required Size size,
	required List<double> h,
	required List<double> v,
}) {
	final Path path = blobPath(size: size, h: h, v: v);
	final Offset centre = Offset(size.width / 2, size.height / 2);
	double reach = 0;
	for (final PathMetric metric in path.computeMetrics()) {
		const int samples = 64;
		for (int i = 0; i <= samples; i++) {
			final Tangent? point = metric.getTangentForOffset(
				metric.length * i / samples,
			);
			if (point == null) continue;
			reach = math.max(reach, (point.position - centre).distance);
		}
	}
	return reach;
}
