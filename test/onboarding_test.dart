// First-run onboarding (v2): state persistence and migration, every path
// (explore, skip, create, template, connect, Dad reminders), and the rule that
// Personal WhatsApp stays prepare-only. Widget tests mount the real
// AutometaApp on the real service graph (SQLite via ffi); only device edges
// are faked.
import 'package:autometa/app_services.dart';
import 'package:autometa/cloud/cloud_session.dart';
import 'package:autometa/core/security/secret_store.dart';
import 'package:autometa/data/db/app_database.dart';
import 'package:autometa/domain/capabilities/execution_capabilities.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/domain/onboarding/onboarding_state.dart';
import 'package:autometa/domain/schedule/schedule_calculator.dart';
import 'package:autometa/domain/validation/workflow_validator.dart';
import 'package:autometa/services/connections/connection_manager.dart';
import 'package:autometa/services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:autometa/services/scheduler/alarm_platform.dart';
import 'package:autometa/services/settings/settings_service.dart';
import 'package:autometa/services/templates/dad_reminders.dart';
import 'package:autometa/services/templates/template_gallery.dart';
import 'package:autometa/state/app_state.dart';
import 'package:autometa/ui/app.dart';
import 'package:autometa/ui/screens/builder_screen.dart';
import 'package:autometa/ui/screens/create_screen.dart';
import 'package:autometa/ui/screens/onboarding_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// No network in these tests: any call is a failure the UI must handle.
class OfflineApi extends ApiClient {
  @override
  Future<ApiResponse> send(ApiRequest request) async => ApiResponse(statusCode: 503, body: '{}');
}

void main() {
  // ------------------------------------------------------------------ state
  group('OnboardingState', () {
    test('first launch (nothing stored) shows onboarding', () {
      final OnboardingState s = OnboardingState.fromSettings(const <String, String>{});
      expect(s.shouldShow, isTrue);
      expect(s.outcome, OnboardingOutcome.none);
    });

    test('v1 users (legacy onboarding.complete=true) are migrated as completed v1, not shown again', () {
      final OnboardingState s = OnboardingState.fromSettings(const <String, String>{'onboarding.complete': 'true'});
      expect(s.shouldShow, isFalse);
      expect(s.version, 1);
      expect(s.sawOlderFlow, isTrue, reason: 'a future "what\'s new" can target them without forcing first-run');
    });

    test('completed and skipped both stay dismissed and round-trip through settings', () {
      for (final OnboardingOutcome o in <OnboardingOutcome>[OnboardingOutcome.completed, OnboardingOutcome.skipped]) {
        final OnboardingState s = OnboardingState(version: OnboardingState.currentVersion, outcome: o);
        final OnboardingState back = OnboardingState.fromSettings(s.toSettings());
        expect(back.outcome, o);
        expect(back.version, OnboardingState.currentVersion);
        expect(back.shouldShow, isFalse);
        expect(back.sawOlderFlow, isFalse);
        expect(s.toSettings()['onboarding.complete'], 'true', reason: 'legacy flag kept in sync');
      }
    });

    test('onboarding does not depend on Cloud sign-in (no auth input exists)', () {
      // Same stored settings → same decision, signed in or not: the state is
      // built only from device settings.
      const Map<String, String> stored = <String, String>{'onboarding.version': '2', 'onboarding.outcome': 'completed'};
      expect(OnboardingState.fromSettings(stored).shouldShow, isFalse);
    });
  });

  // ------------------------------------------------------------------ Dad
  group('Dad reminders template set', () {
    int n = 0;
    String ids() => 'id${n++}';

    test('Personal WhatsApp: prepare-only, on this device, inactive drafts, custom times and name', () {
      final List<Workflow> ws = DadReminders.buildDrafts(
        times: const <String, String>{'morning_dad': '06:45', 'night_dad': '21:30'},
        recipient: 'Mum',
        business: false,
        timeZone: 'Africa/Lagos',
        defaultMode: ExecutionMode.cloud,
        idGenerator: ids,
      );
      expect(ws.map((Workflow w) => w.name), <String>['Morning Mum', 'Night Mum']);
      expect(ws.map((Workflow w) => (w.trigger as ScheduleTrigger).timeOfDay), <String>['06:45', '21:30']);
      for (final Workflow w in ws) {
        expect(w.enabled, isFalse, reason: 'drafts go through the activation review');
        final WhatsAppStep s = w.steps.single as WhatsAppStep;
        expect(s.mode, WhatsAppMode.prepare, reason: 'personal WhatsApp is never sent automatically');
        expect(s.recipient, 'Mum');
        expect(w.executionMode, ExecutionMode.onDevice, reason: 'prepare needs the phone; never silently moved to Cloud');
        expect(const WorkflowValidator().validate(w).errors, isEmpty);
      }
    });

    test('WhatsApp Business is an explicit choice: official send, Cloud by default; never prepare', () {
      final List<Workflow> ws = DadReminders.buildDrafts(
        times: const <String, String>{'morning_dad': '07:00', 'evening_dad': '20:00', 'night_dad': '22:00'},
        recipient: 'Dad',
        business: true,
        timeZone: 'Africa/Lagos',
        defaultMode: ExecutionMode.cloud,
        idGenerator: ids,
      );
      expect(ws, hasLength(3));
      for (final Workflow w in ws) {
        expect((w.steps.single as WhatsAppStep).mode, WhatsAppMode.send);
        expect(w.executionMode, ExecutionMode.cloud);
        expect(w.enabled, isFalse);
      }
    });

    test('default times stay 07:00 / 20:00 / 22:00', () {
      expect(DadReminders.templateIds.map(DadReminders.defaultTime), <String>['07:00', '20:00', '22:00']);
    });
  });

  group('V1 onboarding templates', () {
    test('Email Alert = Gmail trigger → condition → notification, Cloud-only', () {
      final Workflow w = TemplateGallery.byId('email_alert')!.instantiate();
      expect(w.trigger, isA<GmailTrigger>());
      expect(w.steps.single, isA<ConditionStep>());
      expect((w.steps.single as ConditionStep).thenSteps.single, isA<NotificationStep>());
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice), isNotEmpty);
      expect(ExecutionCapabilities.check(w, ExecutionMode.cloud), isEmpty);
    });

    test('Scheduled Telegram Message = weekday schedule → Telegram send, Cloud-only, chat placeholder visible', () {
      final Workflow w = TemplateGallery.byId('scheduled_message')!.instantiate();
      expect((w.trigger as ScheduleTrigger).timeOfDay, '08:30');
      final TelegramSendStep s = w.steps.single as TelegramSendStep;
      expect(s.chatId, '@your_channel');
      expect(ExecutionCapabilities.check(w, ExecutionMode.onDevice), isNotEmpty);
    });
  });

  // ------------------------------------------------------------------ UI
  group('first-run UI (real app, real services)', () {
    late AppDatabase db;

    setUpAll(() {
      sqfliteFfiInit();
      ScheduleCalculator.ensureTimeZonesLoaded();
    });

    Future<AppServices> boot() => AppServices.bootstrap(
          database: db,
          secrets: InMemorySecretStore(),
          apiClient: OfflineApi(),
          platform: RecordingAlarmPlatform(),
          enableAlarmManager: false,
          personalWhatsApp: PersonalWhatsAppAdapter(probe: (_) async => true, opener: (_) async => true),
        );

    Widget appFor(AppServices s) {
      final AppState state = AppState(services: s);
      final CloudSession cloud = CloudSession(s);
      state.cloud = cloud;
      return MultiProvider(
        providers: <ChangeNotifierProvider<ChangeNotifier>>[
          ChangeNotifierProvider<AppState>.value(value: state),
          ChangeNotifierProvider<CloudSession>.value(value: cloud),
          ChangeNotifierProvider<SettingsService>.value(value: s.settings),
          ChangeNotifierProvider<ConnectionManager>.value(value: s.connections),
        ],
        child: AutometaApp(services: s),
      );
    }

    /// Lets real SQLite I/O finish, then advances frames and animations.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
      await tester.tap(find.byKey(Key(key)));
      await settle(tester);
    }

    Future<AppServices> start(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final AppServices s = (await tester.runAsync(() async {
        db = await AppDatabase.openInMemory(factory: databaseFactoryFfi);
        return boot();
      }))!;
      // The ffi in-memory database is shared until closed: isolate each test.
      addTearDown(() => tester.runAsync(db.close));
      await tester.pumpWidget(appFor(s));
      await settle(tester);
      return s;
    }

    Future<List<Workflow>> saved(WidgetTester tester, AppServices s) async =>
        (await tester.runAsync(() => s.workflows.getAll()))!;

    testWidgets('first launch: Welcome, no phone number, no WhatsApp/AI choice, no account required', (WidgetTester tester) async {
      await start(tester);
      expect(find.byType(OnboardingScreen), findsOneWidget);
      expect(find.text('Welcome to Autometa'), findsOneWidget);
      expect(find.text('Automate repetitive tasks across the apps and services you use.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing, reason: 'nothing to type on the first screen');
      expect(find.textContaining('Personal'), findsNothing);
      expect(find.text('AI'), findsNothing);
      await tapKey(tester, 'onboarding.continue');
      expect(find.text('How Autometa works'), findsOneWidget);
      expect(find.textContaining('WHEN', findRichText: true), findsWidgets);
      await tapKey(tester, 'onboarding.continue');
      expect(find.text('Choose your first step'), findsOneWidget);
    });

    testWidgets('Explore first: lands on Home, persists completed v2, no fake data, not shown after restart', (WidgetTester tester) async {
      final AppServices s = await start(tester);
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.path.explore');
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
      expect(find.text('Create your first automation'), findsWidgets, reason: 'honest empty state');
      expect(await saved(tester, s), isEmpty, reason: 'no fake automations');
      // "Restart": a fresh service graph over the same database.
      final AppServices again = (await tester.runAsync(boot))!;
      expect(again.settings.onboardingComplete, isTrue);
      expect(again.settings.onboarding.version, OnboardingState.currentVersion);
      expect(again.settings.onboarding.outcome, OnboardingOutcome.completed);
      await tester.pumpWidget(appFor(again));
      await settle(tester);
      expect(find.byType(OnboardingScreen), findsNothing);
      expect(find.byType(AppShell), findsOneWidget);
    });

    testWidgets('Skip setup: persisted as skipped and never forced again', (WidgetTester tester) async {
      final AppServices s = await start(tester);
      await tapKey(tester, 'onboarding.skip');
      expect(find.byType(AppShell), findsOneWidget);
      expect(s.settings.onboarding.outcome, OnboardingOutcome.skipped);
      final AppServices again = (await tester.runAsync(boot))!;
      expect(again.settings.onboardingComplete, isTrue);
      expect(again.settings.onboarding.outcome, OnboardingOutcome.skipped);
      expect(await saved(tester, s), isEmpty);
    });

    testWidgets('Create an automation opens the real create flow', (WidgetTester tester) async {
      await start(tester);
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.path.create');
      expect(find.byType(CreateScreen), findsOneWidget);
    });

    testWidgets('Connect an app opens the Connections tab', (WidgetTester tester) async {
      await start(tester);
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.path.connect');
      expect(find.text('CONNECTIONS'), findsOneWidget);
    });

    testWidgets('Template: opens the real builder preview; nothing is saved until the user confirms', (WidgetTester tester) async {
      final AppServices s = await start(tester);
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.path.templates');
      expect(find.text('Dad reminders'), findsOneWidget, reason: 'Dad reminders are one template among several');
      await tapKey(tester, 'onboarding.template.daily_reminder');
      expect(find.byType(BuilderScreen), findsOneWidget);
      expect(await saved(tester, s), isEmpty);
    });

    testWidgets('Dad reminders: Personal WhatsApp creates prepare-only inactive drafts', (WidgetTester tester) async {
      final AppServices s = await start(tester);
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.continue');
      await tapKey(tester, 'onboarding.path.templates');
      await tapKey(tester, 'onboarding.template.dad');
      expect(find.text('Personal WhatsApp: you tap Send'), findsOneWidget);
      expect(find.textContaining('never sends from your personal WhatsApp'), findsOneWidget);
      await tapKey(tester, 'onboarding.dad.create');
      await settle(tester);
      final List<Workflow> ws = await saved(tester, s);
      expect(ws.map((Workflow w) => w.name).toSet(), <String>{'Morning Dad', 'Evening Dad', 'Night Dad'});
      for (final Workflow w in ws) {
        expect(w.enabled, isFalse);
        expect((w.steps.single as WhatsAppStep).mode, WhatsAppMode.prepare);
      }
      expect(find.byType(AppShell), findsOneWidget);
    });
  });
}
