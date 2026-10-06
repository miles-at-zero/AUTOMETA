import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:flutter_test/flutter_test.dart';

Workflow wf(WorkflowTrigger t, {String tz = 'Africa/Lagos', bool enabled = true, String id = 'w'}) => Workflow(
      id: id,
      name: id,
      timeZone: tz,
      enabled: enabled,
      trigger: t,
      steps: const <WorkflowStep>[NotificationStep(id: 's', body: 'x')],
    );

void main() {
  setUpAll(ScheduleCalculator.ensureTimeZonesLoaded);
  final ScheduleCalculator calc = ScheduleCalculator();

  test('daily 07:00 Lagos (UTC+1) → 06:00 UTC, same day if before', () {
    final DateTime next = calc.nextOccurrence(wf(const ScheduleTrigger(timeOfDay: '07:00')), after: DateTime.utc(2026, 9, 30, 5))!;
    expect(next, DateTime.utc(2026, 9, 30, 6));
  });

  test('daily rolls to tomorrow once passed; boundary is strictly after', () {
    final Workflow w = wf(const ScheduleTrigger(timeOfDay: '07:00'));
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 9, 30, 6)), DateTime.utc(2026, 10, 1, 6));
  });

  test('the three Dad workflows fire at 07:00, 20:00, 22:00 local', () {
    final DateTime from = DateTime.utc(2026, 9, 29, 23); // 00:00 Lagos on the 30th
    final List<DateTime> times = <String>['07:00', '20:00', '22:00']
        .map((String t) => calc.nextOccurrence(wf(ScheduleTrigger(timeOfDay: t)), after: from)!)
        .toList();
    expect(times, <DateTime>[DateTime.utc(2026, 9, 30, 6), DateTime.utc(2026, 9, 30, 19), DateTime.utc(2026, 9, 30, 21)]);
  });

  test('weekdays skip the weekend', () {
    // 2026-10-02 is a Friday. After Friday 09:00 → Monday.
    final Workflow w = wf(const ScheduleTrigger(timeOfDay: '08:00', repeat: ScheduleRepeat.weekdays), tz: 'UTC');
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 10, 2, 9)), DateTime.utc(2026, 10, 5, 8));
  });

  test('weekly Sunday 18:00 (acceptance workflow)', () {
    final Workflow w = wf(const ScheduleTrigger(timeOfDay: '18:00', repeat: ScheduleRepeat.weekly, weekdays: <int>{7}), tz: 'UTC');
    final DateTime next = calc.nextOccurrence(w, after: DateTime.utc(2026, 9, 30))!;
    expect(next, DateTime.utc(2026, 10, 4, 18));
    expect(next.weekday, DateTime.sunday);
  });

  test('monthly on the 31st skips short months', () {
    final Workflow w = wf(const ScheduleTrigger(timeOfDay: '09:00', repeat: ScheduleRepeat.monthly, dayOfMonth: 31), tz: 'UTC');
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 11, 1)), DateTime.utc(2026, 12, 31, 9));
  });

  test('DST: 07:00 in London stays 07:00 wall clock across the change', () {
    final Workflow w = wf(const ScheduleTrigger(timeOfDay: '07:00'), tz: 'Europe/London');
    // BST (UTC+1) before 25 Oct 2026, GMT after.
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 10, 20)), DateTime.utc(2026, 10, 20, 6));
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 10, 27)), DateTime.utc(2026, 10, 27, 7));
  });

  test('unknown time zone falls back without throwing', () {
    expect(calc.nextOccurrence(wf(const ScheduleTrigger(), tz: 'Mars/Olympus'), after: DateTime.utc(2026)), isNotNull);
  });

  test('one-shot date trigger in the past never fires', () {
    final Workflow w = wf(DateTimeTrigger(at: DateTime.utc(2020)));
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026)), isNull);
  });

  test('manual / webhook triggers are not schedulable', () {
    expect(calc.nextOccurrence(wf(const ManualTrigger()), after: DateTime.utc(2026)), isNull);
    expect(calc.nextOccurrence(wf(const WebhookTrigger(token: 't')), after: DateTime.utc(2026)), isNull);
  });

  test('nextRunAcross picks the soonest enabled workflow', () {
    final DateTime from = DateTime.utc(2026, 9, 30, 20); // 21:00 Lagos
    final WorkflowRun? run = calc.nextRunAcross(<Workflow>[
      wf(const ScheduleTrigger(timeOfDay: '07:00'), id: 'morning'),
      wf(const ScheduleTrigger(timeOfDay: '22:00'), id: 'night'),
      wf(const ScheduleTrigger(timeOfDay: '21:30'), id: 'off', enabled: false),
    ], after: from);
    expect(run!.workflow.id, 'night');
  });

  test('interval schedule steps from its anchor', () {
    final Workflow w = wf(ScheduleTrigger(repeat: ScheduleRepeat.interval, intervalMinutes: 60, anchor: DateTime.utc(2026, 1, 1)), tz: 'UTC');
    expect(calc.nextOccurrence(w, after: DateTime.utc(2026, 1, 1, 5, 10)), DateTime.utc(2026, 1, 1, 6));
  });
}
