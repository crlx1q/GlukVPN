import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/models/account_insights.dart';

void main() {
  test('active map preserves unknown origin and real node coordinates', () {
    final map = ActiveMapSnapshot.fromJson(<String,dynamic>{
      'serverTime':'2026-01-01T00:00:00Z','pollAfterMs':5000,'activeTunnels':2,'maxDevices':5,'truncated':false,
      'service':<String,dynamic>{'registrationEnabled':true,'maintenance':false,'retryAfterSec':30},
      'devices':<Object?>[
        <String,dynamic>{'id':'a','deviceName':'Phone','platform':'android','connected':true,'durationSec':9,'origin':null,'node':_node()},
        <String,dynamic>{'id':'b','deviceName':'PC','platform':'windows','connected':true,'durationSec':10,'origin':<String,dynamic>{'lat':51.1,'lon':71.4,'source':'ip-country','approximate':true},'node':_node()},
      ],
    });
    expect(map.devices, hasLength(2));
    expect(map.devices.first.origin, isNull);
    expect(map.devices.last.node.location?.lat, 50.1);
  });

  test('analytics parses shared service budget and retained domains', () {
    final value = AnalyticsSnapshot.fromJson(<String,dynamic>{'period':'week','coverage':<String,dynamic>{'partial':true},'totals':<String,dynamic>{'downloadBytes':12,'uploadBytes':3},'series':<Object?>[],'devices':<Object?>[],'domains':<String,dynamic>{'enabled':true,'windowDays':30,'scope':'retained-session-totals','items':<Object?>[<String,dynamic>{'domain':'example.test','category':'test','downloadBytes':2,'uploadBytes':1,'connections':1}]},'categories':<Object?>[],'budget':<String,dynamic>{'scope':'service','available':true,'usedBytes':5,'budgetBytes':10,'usedPercent':50}});
    expect(value.partial, isTrue);
    expect(value.domains.single.domain, 'example.test');
    expect(value.budget.available, isTrue);
    expect(value.downloadBytes + value.uploadBytes, 15);
  });
}
Map<String,dynamic> _node()=> <String,dynamic>{'id':'n','name':'node','country':'Germany','countryCode':'DE','host':'vpn.test','port':443,'status':'ONLINE','online':true,'connectable':true,'loadPercent':1,'activePeers':1,'capacity':10,'location':<String,dynamic>{'lat':50.1,'lon':8.6,'source':'node-city','approximate':true},'restrictions':<Object?>[]};
