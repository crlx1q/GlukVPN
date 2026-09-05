import 'package:flutter_test/flutter_test.dart';
import 'package:glukvpn/models/models.dart';
import 'package:glukvpn/models/account_insights.dart';

void main() {
  test('subscription label is the plan, not ACTIVE or EXPIRED', () {
    for (final row in <String, String>{'free':'Free','basic':'Basic','pro':'Pro','beta_pro':'β Pro'}.entries) {
      final value=SubscriptionInfo.fromJson(<String,dynamic>{'status':'ACTIVE','plan':row.key});
      expect(value.displayPlan,row.value);
    }
    expect(const SubscriptionInfo(status:'EXPIRED',plan:'pro').displayPlan,'Pro');
    expect(const SubscriptionInfo(status:'ACTIVE').displayPlan,'—');
  });
  test('budget is hidden unless response explicitly marks it admin-only', () {
    expect(ServiceBudget.fromJson(<String,dynamic>{}).adminOnly,false);
    expect(ServiceBudget.fromJson(<String,dynamic>{'available':true}).adminOnly,false);
    expect(ServiceBudget.fromJson(<String,dynamic>{'adminOnly':true}).adminOnly,true);
  });
  test('map preserves all devices rather than the first five', () {
    final snapshot=ActiveMapSnapshot.fromJson(<String,dynamic>{'devices':List.generate(8,(i)=><String,dynamic>{'id':'$i','status':'ACTIVE'})});
    expect(snapshot.devices.length,8);
  });
}
