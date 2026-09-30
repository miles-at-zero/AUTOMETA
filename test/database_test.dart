import 'package:autometa/data/db/app_database.dart';
import 'package:autometa/data/db/sql_engine_ports.dart';
import 'package:autometa/data/repositories/approval_repository.dart';
import 'package:autometa/data/repositories/execution_repository.dart';
import 'package:autometa/data/repositories/recipient.dart';
import 'package:autometa/data/repositories/settings_repository.dart';
import 'package:autometa/data/repositories/workflow_repository.dart';
import 'package:autometa/domain/engine/step_executor.dart';
import 'package:autometa/domain/engine/workflow_engine.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:autometa/core/security/secret_store.dart';
import 'package:autometa/domain/engine/step_context.dart';
import 'package:autometa/domain/engine/step_result.dart';
import 'package:autometa/services/integrations/whatsapp/business_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_integration.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_models.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_step_executor.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:autometa/services/scheduler/alarm_platform.dart';
import 'package:autometa/services/scheduler/scheduler_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fakes.dart';

void main() {
  late AppDatabase db;

  setUpAll(() {
    sqfliteFfiInit();
    ScheduleCalculator.ensureTimeZonesLoaded();
  });
  setUp(() async => db = await AppDatabase.openInMemory(factory: databaseFactoryFfi));
  tearDown(() => db.close());

  test('workflow create / read / edit / delete round-trips the JSON definition', () async {
    final WorkflowRepository repo = WorkflowRepository(db);
    await repo.save(dadWorkflow());
    Workflow? w = await repo.byId('wf-morning');
    expect(w!.name, 'Morning Dad');
    expect((w.trigger as ScheduleTrigger).timeOfDay, '07:00');
    expect((w.steps.single as WhatsAppStep).message, 'Good morning Dad');

    await repo.save(w.copyWith(name: 'Morning Dad v2', trigger: const ScheduleTrigger(timeOfDay: '07:30')));
    w = await repo.byId('wf-morning');
    expect(w!.name, 'Morning Dad v2');
    expect((w.trigger as ScheduleTrigger).timeOfDay, '07:30');

    await repo.setEnabled('wf-morning', false);
    expect((await repo.byId('wf-morning'))!.enabled, isFalse);
    await repo.delete('wf-morning');
    expect(await repo.byId('wf-morning'), isNull);
  });

  test('SQL idempotency: the UNIQUE claim blocks a second execution', () async {
    final SqlIdempotencyStore store = SqlIdempotencyStore(db);
    expect(await store.claim('k1', executionId: 'a'), isTrue);
    expect(await store.claim('k1', executionId: 'b'), isFalse);
  });

  test('engine + SQLite: duplicate slot is skipped and the success row survives', () async {
    final ExecutionRepository executions = ExecutionRepository(db);
    final ScriptedExecutor wa = ScriptedExecutor(StepKind.whatsapp);
    int n = 0;
    final WorkflowEngine engine = WorkflowEngine(
      registry: StepExecutorRegistry(<StepExecutor>[wa]),
      idempotency: SqlIdempotencyStore(db),
      state: FakeState(),
      sink: SqlEngineSink(executions: executions, approvals: ApprovalRepository(db)),
      time: instantTime,
      idGenerator: () => 'e${n++}',
    );
    final DateTime slot = DateTime.utc(2026, 10, 1, 6);
    await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);
    await engine.execute(dadWorkflow(), source: TriggerSource.schedule, scheduledFor: slot);

    final List<ExecutionRecord> all = await executions.recent();
    expect(all.map((ExecutionRecord e) => e.status), containsAll(<ExecutionStatus>[ExecutionStatus.success, ExecutionStatus.skipped]));
    expect(wa.calls, 1);
  });

  test('settings, contacts and variables persist', () async {
    final SettingsRepository settings = SettingsRepository(db);
    await settings.setBool('engine.paused', true);
    expect(await settings.getBool('engine.paused'), isTrue);

    final ContactRepository contacts = ContactRepository(db);
    await contacts.save(const Recipient(id: 'c1', alias: 'Dad', displayName: 'Dad', phoneE164: '+234 800 000 0000'));
    final Recipient? dad = await contacts.byAlias('dad');
    expect(dad!.dialableNumber, '2348000000000');
    expect(dad.maskedNumber, isNot(contains('8000000')));

    final VariableRepository vars = VariableRepository(db);
    await vars.put('city', 'Port Harcourt');
    expect((await vars.all())['city'], 'Port Harcourt');
  });

  test('personal WhatsApp: approval by default, then honest hand-off (never "sent")', () async {
    final ContactRepository contacts = ContactRepository(db);
    await contacts.save(const Recipient(id: 'c', alias: 'Dad', displayName: 'Dad', phoneE164: '+2348000000000'));
    Uri? opened;
    final WhatsAppIntegration integration = WhatsAppIntegration(
      personalAdapter: PersonalWhatsAppAdapter(probe: (_) async => true, opener: (Uri u) async {
        opened = u;
        return true;
      }),
      businessAdapter: BusinessWhatsAppAdapter(apiClient: HttpApiClient(), secrets: InMemorySecretStore()),
      activeTypeProvider: () async => WhatsAppAccountType.personal,
      activeTypeWriter: (_) async {},
    );
    final WhatsAppStepExecutor exec = WhatsAppStepExecutor(integration: integration, contacts: contacts);
    const WhatsAppStep step = WhatsAppStep(id: 's', recipient: 'Dad', message: 'Good morning {{name}}');
    StepContext ctx({bool granted = false}) => StepContext.create(
          workflow: dadWorkflow(),
          executionId: 'e',
          dryRun: false,
          source: TriggerSource.schedule,
          scheduledFor: DateTime.now(),
          approvalGranted: granted,
          approvedStepId: granted ? 's' : null,
          defaultRecipientName: 'Dad',
        );

    final StepResult first = await exec.execute(step, ctx());
    expect(first.outcome, StepOutcome.awaitingApproval);
    expect(first.approval!.fields['Message'], 'Good morning Dad');
    expect(opened, isNull, reason: 'nothing happens before approval');

    final StepResult approved = await exec.execute(step, ctx(granted: true));
    expect(approved.code, 'whatsapp.handed_to_user');
    expect(approved.detail, isNot(contains('Sent')));
    expect(opened!.host, 'wa.me');
  });

  test('WhatsApp not connected fails with a clear reason', () async {
    final WhatsAppIntegration integration = WhatsAppIntegration(
      personalAdapter: PersonalWhatsAppAdapter(probe: (_) async => true),
      businessAdapter: BusinessWhatsAppAdapter(apiClient: HttpApiClient(), secrets: InMemorySecretStore()),
      activeTypeProvider: () async => null,
      activeTypeWriter: (_) async {},
    );
    final StepResult r = await WhatsAppStepExecutor(integration: integration, contacts: ContactRepository(db)).execute(
      const WhatsAppStep(id: 's', message: 'x'),
      StepContext.create(workflow: dadWorkflow(), executionId: 'e', dryRun: false, source: TriggerSource.manual, scheduledFor: DateTime.now()),
    );
    expect(r.isFailure, isTrue);
    expect(r.code, 'whatsapp.not_connected');
  });

  test('scheduler arms enabled workflows with AlarmManager and disarms on pause', () async {
    final WorkflowRepository repo = WorkflowRepository(db);
    await repo.save(dadWorkflow());
    await repo.save(dadWorkflow(id: 'wf-night', time: '22:00').copyWith(enabled: false));
    final RecordingAlarmPlatform platform = RecordingAlarmPlatform();
    final SchedulerService scheduler = SchedulerService(platform: platform, calculator: ScheduleCalculator(), workflows: repo);

    final ScheduleSyncReport report = await scheduler.syncAll();
    expect(report.armed, 1);
    expect(platform.scheduled.containsKey(alarmIdFor('wf-morning')), isTrue);
    expect(platform.scheduled.containsKey(alarmIdFor('wf-night')), isFalse);

    await scheduler.disarmAll();
    expect(platform.scheduled.keys.where((int k) => k != AlarmIds.maintenance), isEmpty);
  });
}
