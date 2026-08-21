import 'dart:ui';

import 'geo.dart';

/// Camera for the flat world map when it is used as a full-bleed backdrop.
///
/// The map is a 119x60 equirectangular strip. Dropped into a tall phone screen
/// at a modest zoom it looks like exactly that - a band across the middle with
/// dead space above and below it. Filling the screen means zooming until the
/// map's *height* covers the viewport, and that is a different number on every
/// device, so it is computed instead of guessed.
///
/// [topAnchored] then pins the map's top edge near the top of the screen rather
/// than centring it: the world belongs above the readouts, not behind them.
class FlatMapView {
	const FlatMapView({required this.zoom, required this.focus});

	/// `DottedWorld.zoom`: 1 fits the map's full width across the widget.
	final double zoom;

	/// `DottedWorld.focus`: which point of the map sits in the middle of the
	/// widget, in 0..1 map fractions.
	final Offset focus;

	/// Screen pixels per map unit at this zoom.
	static double scaleFor({required Size viewport, required double coverage}) =>
			coverage * viewport.height / mapHeight;

	/// A map that covers [coverage] of the viewport's height, sits [topPadding]
	/// pixels below the top edge, and is centred horizontally on [centreOn].
	///
	/// The map's top edge lands at `height / 2 - focus.dy * mapHeight * scale`;
	/// solving that for the padding we want is the whole trick.
	static FlatMapView topAnchored({
		required Size viewport,
		required MapPoint centreOn,
		double coverage = 0.8,
		double topPadding = 0,
	}) {
		if (viewport.width <= 0 || viewport.height <= 0) {
			return FlatMapView(zoom: 1, focus: Offset(centreOn.fx, centreOn.fy));
		}
		final scale = scaleFor(viewport: viewport, coverage: coverage);
		final zoom = scale * mapWidth / viewport.width;
		final focusY = (viewport.height / 2 - topPadding) / (mapHeight * scale);
		return FlatMapView(
			zoom: zoom,
			focus: Offset(centreOn.fx.clamp(0.0, 1.0), focusY),
		);
	}

	/// Where the map's top edge sits, in pixels from the top of the viewport.
	/// Exists so a test can check the anchoring without pumping a widget.
	double topEdge({required Size viewport}) {
		final scale = zoom * viewport.width / mapWidth;
		return viewport.height / 2 - focus.dy * mapHeight * scale;
	}
}
