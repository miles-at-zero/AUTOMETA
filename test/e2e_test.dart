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
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:autometa/services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_models.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:autometa/services/scheduler/alarm_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:whatsapp_auto_send/whatsapp_auto_send.dart';

/// Behaves like the real Android bindings did before the fix: cancelAll()
/// only knows alarms armed in *this* process, so after a restart it is a no-op.
class FreshProcessAlarmPlatform extends RecordingAlarmPlatform {
  @override
  Future<void> cancelAll() async => events.add('cancelAll(no-op)');
}

class FakeWhatsAppPhone {
  bool autoSendOn = true;
  AutoSendStatus nextResult = AutoSendStatus.sent;
  final List<String> sent = <String>[];
  final List<Uri> opened = <Uri>[];

  PersonalWhatsAppAdapter adapter() => PersonalWhatsAppAdapter(
        probe: (_) async => true,
        opener: (Uri u) async {
          opened.add(u);
          return true;
        },
        autoSendStatus: () async =>
            AutoSendServiceStatus(enabled: autoSendOn, running: autoSendOn, whatsappPackage: 'com.whatsapp'),
        autoSender: (String phone, String text) async {
          if (nextResult == AutoSendStatus.sent) sent.add('$phone|$text');
          return AutoSendResult(nextResult, nextResult == AutoSendStatus.sent ? null : 'simulated ${nextResult.name}');
        },
      );
}

class FakeGraphApi extends ApiClient {
  final List<ApiRequest> calls = <ApiRequest>[];
  @override
  Future<ApiResponse> send(ApiRequest request) async {
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

Workflow dad(String id, String name, String time, String message, {String? account, bool? ask = false}) => Workflow(
      id: id,
      name: name,
      timeZone: 'Africa/Lagos',
      maxRetries: 0,
      trigger: ScheduleTrigger(timeOfDay: time),
      steps: <WorkflowStep>[
        WhatsAppStep(
          id: '$id-s1',
          mode: WhatsAppMode.send,
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
      expect(r.stepResults.last.code, 'whatsapp.sent_from_phone');
      // Re-armed strictly after the slot that just ran.
      expect(alarms.scheduled[alarmIdFor(w.id)]!.isAfter(armedFor), isTrue);
    }
    expect(phone.sent, <String>[
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
    expect(phone.sent.length, 1);
  });

  test('alarm delivered hours late (reboot / deep Doze) is skipped, not sent', () async {
    final DateTime fiveHoursAgo = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final ExecutionRecord r = (await fire('wf-morning', at: fiveHoursAgo))!;
    expect(r.status, ExecutionStatus.skipped);
    expect(phone.sent, isEmpty);
    // Delivery is logged for the Reliability screen.
    expect((await app.diagnostics.history()).single.late.inHours, greaterThanOrEqualTo(4));
  });

  test('slightly late alarm (under 2 h) still runs', () async {
    final DateTime late = DateTime.now().toUtc().subtract(const Duration(minutes: 20));
    final ExecutionRecord r = (await fire('wf-morning', at: late))!;
    expect(r.status, ExecutionStatus.success);
    expect(phone.sent.length, 1);
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
    expect(phone.sent, isEmpty);

    // Resume re-arms everything.
    await fresh.settings.setPaused(false);
    expect((await fresh.scheduler.syncAll()).armed, 3);
  });

  test('personal WhatsApp without auto-send: waits for you, opens the prefilled chat, never claims sent', () async {
    phone.autoSendOn = false;
    final ExecutionRecord r = (await fire('wf-morning', at: DateTime.now().toUtc()))!;
    expect(r.status, ExecutionStatus.waitingApproval);
    expect(phone.sent, isEmpty);
    expect(phone.opened, isEmpty);

    final List<ApprovalTicket> pending = await app.approvals.pending();
    expect(pending.single.body, 'Good morning Dad');

    final ExecutionRecord after = (await app.execution.resolveApproval(ticketId: pending.single.id, approved: true))!;
    expect(phone.opened.single.host, 'wa.me');
    expect(phone.opened.single.path, '/2348012345678');
    expect(phone.opened.single.queryParameters['text'], 'Good morning Dad');
    expect(phone.sent, isEmpty, reason: 'the user taps Send, not AUTOMETA');
    expect(after.stepResults.last.code, 'whatsapp.handed_to_user');
    expect(after.stepResults.last.code, isNot('whatsapp.sent_from_phone'));
  });

  test('rejecting the approval sends nothing', () async {
    phone.autoSendOn = false;
    await fire('wf-evening', at: DateTime.now().toUtc());
    final ApprovalTicket t = (await app.approvals.pending()).single;
    await app.execution.resolveApproval(ticketId: t.id, approved: false);
    expect(phone.opened, isEmpty);
    expect(phone.sent, isEmpty);
  });

  test('locked phone fails clearly; a later retry succeeds', () async {
    phone.nextResult = AutoSendStatus.locked;
    final ExecutionRecord failed = (await fire('wf-night', at: DateTime.now().toUtc()))!;
    expect(failed.status, ExecutionStatus.failed);
    expect(failed.failureReason, contains('locked'));
    expect(phone.sent, isEmpty);

    phone.nextResult = AutoSendStatus.sent;
    final ExecutionRecord retried = (await app.execution.retry(failed.id))!;
    expect(retried.status, ExecutionStatus.success);
    expect(phone.sent, <String>['2348012345678|Good night Dad']);
  });

  test('dry run simulates without sending or consuming the slot', () async {
    final Workflow w = (await app.workflows.byId('wf-morning'))!;
    final report = await app.execution.dryRun(w);
    expect(report.toString(), isNotEmpty);
    expect(phone.sent, isEmpty);
    expect(phone.opened, isEmpty);
    // The real run afterwards still goes out.
    await fire('wf-morning', at: DateTime.now().toUtc());
    expect(phone.sent.length, 1);
  });

  test('workflows persist across a restart', () async {
    final AppServices fresh = await boot();
    final List<Workflow> all = await fresh.workflows.getAll();
    expect(all.map((Workflow w) => w.name), containsAll(<String>['Morning Dad', 'Evening Dad', 'Night Dad']));
    final WhatsAppStep step = (await fresh.workflows.byId('wf-night'))!.steps.single as WhatsAppStep;
    expect(step.message, 'Good night Dad');
    expect(step.mode, WhatsAppMode.send);
  });

  test('per-automation account: Business step uses the Cloud API while others stay personal', () async {
    await app.saveWhatsAppBusinessConfig(phoneNumberId: '1069', accessToken: 'EAAtest');
    expect(await app.whatsapp.activeType(), WhatsAppAccountType.personal, reason: 'adding Business must not change the default');
    await app.workflows.save(dad('wf-biz', 'Biz Dad', '09:00', 'Hello from Business', account: 'business'));

    final ExecutionRecord biz = (await fire('wf-biz', at: DateTime.now().toUtc()))!;
    expect(biz.status, ExecutionStatus.success, reason: biz.failureReason);
    final ApiRequest post = api.calls.lastWhere((ApiRequest c) => c.method == 'POST');
    expect(post.url, contains('/1069/messages'));
    expect(post.body, contains('Hello from Business'));
    expect(phone.sent, isEmpty);

    await fire('wf-morning', at: DateTime.now().toUtc());
    expect(phone.sent, <String>['2348012345678|Good morning Dad']);
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
