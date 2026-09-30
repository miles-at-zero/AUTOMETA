import 'package:autometa/services/notifications/notification_service.dart';
import 'package:autometa/services/scheduler/alarm_platform.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('notification preferences round-trip through the settings map', () {
    const NotificationPreferences p = NotificationPreferences(onCompleted: false, onUpcoming: true, upcomingLeadMinutes: 5);
    final NotificationPreferences back = NotificationPreferences.fromMap(p.toMap());
    expect(back.onCompleted, isFalse);
    expect(back.onUpcoming, isTrue);
    expect(back.onFailed, isTrue);
    expect(back.upcomingLeadMinutes, 5);
  });

  test('defaults: failures and approvals on, upcoming off', () {
    final NotificationPreferences d = NotificationPreferences.fromMap(const <String, String>{});
    expect(d.onFailed && d.onApproval && d.onConnectionFailure, isTrue);
    expect(d.onUpcoming, isFalse);
  });

  test('alarm ids are stable and never collide with reserved ids', () {
    expect(alarmIdFor('wf-morning'), alarmIdFor('wf-morning'));
    expect(alarmIdFor('wf-morning'), isNot(alarmIdFor('wf-evening')));
    expect(alarmIdFor('x'), lessThan(AlarmIds.maintenance));
  });

  test('unavailable platform reports itself honestly', () async {
    const UnavailableAlarmPlatform p = UnavailableAlarmPlatform();
    expect(await p.isAvailable, isFalse);
    expect(await p.notificationsPermitted, isFalse);
  });
}
