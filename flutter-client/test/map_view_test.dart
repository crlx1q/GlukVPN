import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/geo.dart';
import 'package:glukvpn/utils/map_view.dart';

/// The flat map used to read as a narrow band across the middle of the screen.
/// [FlatMapView.topAnchored] is the fix: it zooms until the map covers the
/// requested share of the viewport height and pins its top edge, so the world
/// sits above the readouts instead of behind them.
void main() {
  const Size phone = Size(390, 844);
  const Size tablet = Size(834, 1194);
  final MapPoint germany = countryPoint('DE')!;

  test('the map top edge lands exactly where it was asked to', () {
    for (final double padding in <double>[0, -6, 24]) {
      final FlatMapView view = FlatMapView.topAnchored(
        viewport: phone,
        centreOn: germany,
        coverage: 0.88,
        topPadding: padding,
      );
      expect(view.topEdge(viewport: phone), closeTo(padding, 0.001));
    }
  });

  test('coverage decides how much of the height the map fills', () {
    for (final double coverage in <double>[0.5, 0.8, 0.88, 1.2]) {
      final FlatMapView view = FlatMapView.topAnchored(
        viewport: phone,
        centreOn: germany,
        coverage: coverage,
      );
      final double scale = view.zoom * phone.width / mapWidth;
      expect(mapHeight * scale, closeTo(coverage * phone.height, 0.001));
    }
  });

  test('more coverage means more zoom', () {
    final FlatMapView small = FlatMapView.topAnchored(
      viewport: phone,
      centreOn: germany,
      coverage: 0.6,
    );
    final FlatMapView large = FlatMapView.topAnchored(
      viewport: phone,
      centreOn: germany,
      coverage: 0.9,
    );
    expect(large.zoom, greaterThan(small.zoom));
  });

  test('the horizontal centre follows the requested point', () {
    final FlatMapView view = FlatMapView.topAnchored(
      viewport: phone,
      centreOn: germany,
      coverage: 0.88,
    );
    expect(view.focus.dx, closeTo(germany.fx, 1e-9));
    expect(view.focus.dx, inInclusiveRange(0, 1));
  });

  test('a taller viewport needs a bigger zoom for the same coverage', () {
    // A wide screen already shows more map per pixel, so it needs less zoom to
    // cover the same fraction of its height.
    final FlatMapView onPhone = FlatMapView.topAnchored(
      viewport: phone,
      centreOn: germany,
      coverage: 0.88,
    );
    final FlatMapView onTablet = FlatMapView.topAnchored(
      viewport: tablet,
      centreOn: germany,
      coverage: 0.88,
    );
    expect(onPhone.zoom, greaterThan(onTablet.zoom));
    // Both still put the top edge at 0.
    expect(onPhone.topEdge(viewport: phone), closeTo(0, 0.001));
    expect(onTablet.topEdge(viewport: tablet), closeTo(0, 0.001));
  });

  test('scaleFor is pixels per map unit', () {
    expect(
      FlatMapView.scaleFor(viewport: phone, coverage: 1),
      closeTo(phone.height / mapHeight, 1e-9),
    );
  });

  test('an empty viewport degrades to a plain centred map', () {
    final FlatMapView view = FlatMapView.topAnchored(
      viewport: Size.zero,
      centreOn: germany,
    );
    expect(view.zoom, 1);
    expect(view.focus.dx, closeTo(germany.fx, 1e-9));
    expect(view.focus.dy, closeTo(germany.fy, 1e-9));
  });
}
