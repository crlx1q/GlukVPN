import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/utils/geo.dart';
import 'package:glukvpn/utils/map_view.dart';
import 'package:glukvpn/models/account_insights.dart';
import 'package:glukvpn/widgets/active_account_map.dart';
import 'package:glukvpn/widgets/dotted_world.dart';

void main() {
 test('background camera includes every route, including distant devices', () {
  for(final width in <double>[320,390,800]){
   final size=Size(width,800),points=<MapPoint>[projectLatLon(48,68),projectLatLon(40,-99),projectLatLon(50,9)];
   final view=FlatMapView.fitConnections(viewport:size,points:points,maxZoom:4),scale=view.zoom*width/mapWidth;
   for(final p in points){final x=width/2+(p.x-view.focus.dx*mapWidth)*scale;final y=400+(p.y-view.focus.dy*mapHeight)*scale;expect(x,inInclusiveRange(24,width-24));expect(y,inInclusiveRange(90,520));}
  }
 });
 test('current account route is marked; pending and invalid coordinates do not draw', () {
  final snapshot=ActiveMapSnapshot.fromJson({'devices':[
   {'id':'self','isCurrent':true,'status':'ACTIVE','origin':{'lat':48,'lon':68},'node':{'location':{'lat':50,'lon':9}}},
   {'id':'pending','status':'PENDING','origin':{'lat':48,'lon':68},'node':{'location':{'lat':50,'lon':9}}},
   {'id':'unknown','status':'ACTIVE','node':{'location':{'lat':50,'lon':9}}},
  ]});
  final arcs=accountMapArcs(snapshot);expect(arcs.length,1);expect((arcs.single as AccountConnectionArc).isCurrent,true);
 });
}
