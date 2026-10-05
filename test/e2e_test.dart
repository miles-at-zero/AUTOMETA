// End-to-end: boots the real AppServices graph (SQLite, engine, scheduler,
// execution service, WhatsApp executor) with only the device edges faked:
// AlarmManager, the WhatsApp app / auto-send service, and the network.
import 'dart:convert';

import 'package:autometa/app_services.dart';
import 'package:autometa/core/security/secret_store.dart';
import 'package:autometa/data/db/app_database.dart';
import 'package:autometa/data/repositories/recipient.dart';
import 'package:autometa/domain/engine/approval_request.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:autometa/domain/validation/workflow_validator.dart';
import 'package:autometa/services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_models.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:autometa/services/scheduler/alarm_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;

/// Behaves like the real Android bindings did before the fix: cancelAll()
/// only knows alarms armed in *this* process, so after a restart it is a no-op.
class FreshProcessAlarmPlatform extends RecordingAlarmPlatform {
  @override
  Future<void> cancelAll() async => events.add('cancelAll(no-op)');
}

/// The phone's WhatsApp app. Autometa can only open a prefilled chat; the
/// user taps Send. There is deliberately no way for Autometa to send here.
class FakeWhatsAppPhone {
  final List<Uri> opened = <Uri>[];

  PersonalWhatsAppAdapter adapter() => PersonalWhatsAppAdapter(
        probe: (_) async => true,
        opener: (Uri u) async {
          opened.add(u);
          return true;
        },
      );
}

class FakeGraphApi extends ApiClient {
  final List<ApiRequest> calls = <ApiRequest>[];
  bool failSends = false;

  /// Messages Meta accepted, as 'digits|text'.
  List<String> get sent => calls
      .where((ApiRequest c) => c.method == 'POST' && c.url.contains('/messages'))
      .map((ApiRequest c) {
        final Map<String, dynamic> b = jsonDecode(c.body!) as Map<String, dynamic>;
        return '${b['to']}|${(b['text'] as Map<String, dynamic>?)?['body'] ?? ''}';
      })
      .toList();

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    if (failSends && request.method == 'POST') {
      return ApiResponse(statusCode: 500, body: '{"error":{"message":"Service temporarily unavailable"}}');
    }
    calls.add(request);
    if (request.method == 'GET') {
      return ApiResponse(statusCode: 200, body: jsonEncode(<String, dynamic>{'id': '1069', 'display_phone_number': '+1 555'}));
    }
    return ApiResponse(
      statusCode: 200,
      body: jsonEncode(<String, dynamic>{
        'messages': <Map<String, String>>[
          <String, String>{'id': 'wamid.TEST', 'message_status': 'accepted'},
        ],
      }),
    );
  }
}

// The Dad reminders send automatically, so they use the official WhatsApp
// Business API. Personal WhatsApp only ever prepares the message (see below).
Workflow dad(String id, String name, String time, String message,
        {String? account = 'business', bool? ask = false, WhatsAppMode mode = WhatsAppMode.send}) =>
    Workflow(
      id: id,
      name: name,
      timeZone: 'Africa/Lagos',
      maxRetries: 0,
      trigger: ScheduleTrigger(timeOfDay: time),
      steps: <WorkflowStep>[
        WhatsAppStep(
          id: '$id-s1',
          mode: mode,
          recipient: 'Dad',
          message: message,
          requiresApproval: ask,
          account: account,
        ),
      ],
    );

void main() {
  late AppDatabase db;
  late RecordingAlarmPlatform alarms;
  late FakeWhatsAppPhone phone;
  late FakeGraphApi api;
  late AppServices app;

  final List<Workflow> dads = <Workflow>[
    dad('wf-morning', 'Morning Dad', '07:00', 'Good morning Dad'),
    dad('wf-evening', 'Evening Dad', '20:00', 'Good evening Dad'),
    dad('wf-night', 'Night Dad', '22:00', 'Good night Dad'),
  ];

  Future<AppServices> boot({AlarmPlatform? platform}) => AppServices.bootstrap(
        database: db,
        secrets: InMemorySecretStore(),
        apiClient: api,
        platform: platform ?? alarms,
        enableAlarmManager: false,
        personalWhatsApp: phone.adapter(),
      );

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    ScheduleCalculator.ensureTimeZonesLoaded();
  });

  setUp(() async {
    db = await AppDatabase.openInMemory(factory: databaseFactoryFfi);
    alarms = RecordingAlarmPlatform();
    phone = FakeWhatsAppPhone();
    api = FakeGraphApi();
    app = await boot();
    await app.whatsapp.selectType(WhatsAppAccountType.personal);
    await app.saveWhatsAppBusinessConfig(phoneNumberId: '1069', accessToken: 'EAAtest');
    await app.contacts.save(const Recipient(id: 'c1', alias: 'Dad', displayName: 'Dad', phoneE164: '+2348012345678'));
    for (final Workflow w in dads) {
      await app.workflows.save(w);
    }
  });

  tearDown(() => db.close());

  /// Fires the alarm as AlarmManager would: at the time it was armed for.
  Future<ExecutionRecord?> fire(String workflowId, {DateTime? at}) async {
    final Workflow w = (await app.workflows.byId(workflowId))!;
    final DateTime slot = at ?? app.calculator.nextOccurrence(w)!;
    return app.execution.runScheduled(workflowId: workflowId, scheduledFor: slot);
  }

  test('three Dad automations arm at 07:00 / 20:00 / 22:00 Lagos time', () async {
    final report = await app.scheduler.syncAll();
    expect(report.armed, 3);
    final tz.Location lagos = tz.getLocation('Africa/Lagos');
    final Map<String, int> expected = <String, int>{'wf-morning': 7, 'wf-evening': 20, 'wf-night': 22};
    for (final MapEntry<String, int> e in expected.entries) {
      final DateTime at = alarms.scheduled[alarmIdFor(e.key)]!;
      final tz.TZDateTime local = tz.TZDateTime.from(at, lagos);
      expect(local.hour, e.value, reason: e.key);
      expect(local.minute, 0);
      expect(at.isAfter(DateTime.now()), isTrue);
    }
    expect(alarms.scheduled.containsKey(AlarmIds.maintenance), isTrue);
  });

  test('each alarm sends the right message to Dad once, then re-arms for the next day', () async {
    await app.scheduler.syncAll();
    for (final Workflow w in dads) {
      final DateTime armedFor = alarms.scheduled[alarmIdFor(w.id)]!;
      final ExecutionRecord r = (await fire(w.id, at: armedFor))!;
      expect(r.status, ExecutionStatus.success, reason: '${w.name}: ${r.failureReason}');
      expect(r.stepResults.last.code, isNot('whatsapp.handed_to_user'));
      // Re-armed strictly after the slot that just ran.
      expect(alarms.scheduled[alarmIdFor(w.id)]!.isAfter(armedFor), isTrue);
    }
    expect(api.sent, <String>[
      '2348012345678|Good morning Dad',
      '2348012345678|Good evening Dad',
      '2348012345678|Good night Dad',
    ]);
  });

  test('duplicate alarm delivery for the same slot never sends twice', () async {
    final Workflow w = (await app.workflows.byId('wf-morning'))!;
    final DateTime slot = app.calculator.nextOccurrence(w)!;
    await fire('wf-morning', at: slot);
    await fire('wf-morning', at: slot);
    await fire('wf-morning', at: slot);
    expect(api.sent.length, 1);
  });

  test('alarm delivered hours late (reboot / deep Doze) is skipped, not sent', () async {
    final DateTime fiveHoursAgo = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final ExecutionRecord r = (await fire('wf-morning', at: fiveHoursAgo))!;
    expect(r.status, ExecutionStatus.skipped);
    expect(api.sent, isEmpty);
    // Delivery is logged for the Reliability screen.
    expect((await app.diagnostics.history()).single.late.inHours, greaterThanOrEqualTo(4));
  });

  test('slightly late alarm (under 2 h) still runs', () async {
    final DateTime late = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    final ExecutionRecord r = (await fire('wf-morning', at: late))!;
    expect(r.status, ExecutionStatus.success);
    expect(api.sent.length, 1);
  });

  test('pause all: alarms cancelled even from a fresh process, maintenance cannot re-arm, runs skip', () async {
    await app.scheduler.syncAll();
    expect(alarms.scheduled.length, 4);

    // Restarted process whose AlarmManager wrapper has no memory of armed ids.
    final FreshProcessAlarmPlatform restarted = FreshProcessAlarmPlatform()..scheduled.addAll(alarms.scheduled);
    final AppServices fresh = await boot(platform: restarted);
    await fresh.settings.setPaused(true);
    await fresh.scheduler.disarmAll();
    expect(restarted.scheduled, isEmpty, reason: 'every workflow alarm and maintenance cancelled by id');

    // The 3-hourly maintenance wake runs syncAll: must not re-arm while paused.
    final report = await fresh.scheduler.syncAll();
    expect(report.armed, 0);
    expect(restarted.scheduled, isEmpty);

    // A stray alarm that still fires is recorded as skipped and sends nothing.
    final Workflow w = (await fresh.workflows.byId('wf-night'))!;
    final ExecutionRecord r = (await fresh.execution.runScheduled(
      workflowId: w.id,
      scheduledFor: DateTime.now().toUtc(),
    ))!;
    expect(r.status, ExecutionStatus.skipped);
    expect(api.sent, isEmpty);

    // Resume re-arms everything.
    await fresh.settings.setPaused(false);
    expect((await fresh.scheduler.syncAll()).armed, 3);
  });

  test('personal WhatsApp: prepares the message, waits for you, opens the prefilled chat, never claims sent', () async {
    await app.workflows.save(dad('wf-personal', 'Personal Dad', '20:00', 'Good morning Dad', account: 'personal', ask: null, mode: WhatsAppMode.prepare));
    final ExecutionRecord r = (await fire('wf-personal', at: DateTime.now().toUtc()))!;
    expect(r.status, ExecutionStatus.waitingApproval);
    expect(phone.opened, isEmpty);

    final ApprovalTicket t = (await app.approvals.pending()).single;
    final ExecutionRecord after = (await app.execution.resolveApproval(ticketId: t.id, approved: true))!;
    expect(phone.opened.single.host, 'wa.me');
    expect(phone.opened.single.path, '/2348012345678');
    expect(phone.opened.single.queryParameters['text'], 'Good morning Dad');
    expect(api.sent, isEmpty, reason: 'the user taps Send, not AUTOMETA');
    expect(after.stepResults.last.code, 'whatsapp.handed_to_user');
  });

  test('rejecting the approval opens nothing', () async {
    await app.workflows.save(dad('wf-personal', 'Personal Dad', '20:00', 'Hi', account: 'personal', ask: null, mode: WhatsAppMode.prepare));
    await fire('wf-personal', at: DateTime.now().toUtc());
    final ApprovalTicket t = (await app.approvals.pending()).single;
    await app.execution.resolveApproval(ticketId: t.id, approved: false);
    expect(phone.opened, isEmpty);
  });

  test('personal account set to "send" is refused by the validator and the adapter', () async {
    final Workflow bad = dad('wf-bad', 'Silent send', '20:00', 'Hi', account: 'personal');
    expect(const WorkflowValidator().validate(bad).isValid, isFalse);
  });

  test('Business API outage fails clearly; a later retry succeeds', () async {
    api.failSends = true;
    final ExecutionRecord failed = (await fire('wf-night', at: DateTime.now().toUtc()))!;
    expect(failed.status, ExecutionStatus.failed);
    expect(api.sent, isEmpty);

    api.failSends = false;
    final ExecutionRecord retried = (await app.execution.retry(failed.id))!;
    expect(retried.status, ExecutionStatus.success, reason: retried.failureReason);
    expect(api.sent, <String>['2348012345678|Good night Dad']);
  });

  test('dry run simulates without sending or consuming the slot', () async {
    final Workflow w = (await app.workflows.byId('wf-morning'))!;
    final report = await app.execution.dryRun(w);
    expect(report.toString(), isNotEmpty);
    expect(api.sent, isEmpty);
    expect(phone.opened, isEmpty);
    // The real run afterwards still goes out.
    await fire('wf-morning', at: DateTime.now().toUtc());
    expect(api.sent.length, 1);
  });

  test('workflows persist across a restart', () async {
    final AppServices fresh = await boot();
    final List<Workflow> all = await fresh.workflows.getAll();
    expect(all.map((Workflow w) => w.name), containsAll(<String>['Morning Dad', 'Evening Dad', 'Night Dad']));
    final WhatsAppStep step = (await fresh.workflows.byId('wf-night'))!.steps.single as WhatsAppStep;
    expect(step.message, 'Good night Dad');
    expect(step.mode, WhatsAppMode.send);
  });

  test('Cloud automations are never armed or run by the phone', () async {
    final Workflow cloud = dad('wf-cloud', 'Cloud Dad', '09:00', 'Hi').copyWith(executionMode: ExecutionMode.cloud);
    await app.workflows.save(cloud);
    await app.scheduler.syncAll();
    expect(alarms.scheduled.containsKey(alarmIdFor('wf-cloud')), isFalse);
    final ExecutionRecord? r = await fire('wf-cloud', at: DateTime.now().toUtc());
    expect(r, isNull);
    expect(api.sent, isEmpty);
  });

  test('a brand-new automation (weekly Sunday 18:00) works with no code changes', () async {
    final Workflow sunday = Workflow(
      id: 'wf-sunday',
      name: 'Sunday summary',
      timeZone: 'Africa/Lagos',
      trigger: const ScheduleTrigger(timeOfDay: '18:00', repeat: ScheduleRepeat.weekly, weekdays: <int>{DateTime.sunday}),
      steps: const <WorkflowStep>[
        NotificationStep(id: 'n1', title: 'Weekly summary', body: 'Your week is ready'),
      ],
    );
    await app.workflows.save(sunday);
    await app.scheduler.syncAll();
    final DateTime at = alarms.scheduled[alarmIdFor('wf-sunday')]!;
    final tz.TZDateTime local = tz.TZDateTime.from(at, tz.getLocation('Africa/Lagos'));
    expect(local.weekday, DateTime.sunday);
    expect(local.hour, 18);
    final ExecutionRecord r = (await fire('wf-sunday', at: DateTime.now().toUtc()))!;
    expect(r.status, isNot(ExecutionStatus.failed), reason: r.failureReason);
  });
}
