import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:url_launcher/url_launcher.dart' as launcher;

import 'core/constants/app_constants.dart';
import 'core/security/secret_store.dart';
import 'core/utils/logger.dart';
import 'data/db/app_database.dart';
import 'data/repositories/approval_repository.dart';
import 'data/repositories/connection_repository.dart';
import 'data/repositories/execution_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'data/repositories/workflow_repository.dart';
import 'data/db/sql_engine_ports.dart';
import 'domain/engine/engine_ports.dart';
import 'domain/engine/step_executor.dart';
import 'domain/engine/workflow_engine.dart';
import 'domain/models/step.dart';
import 'domain/schedule/schedule_calculator.dart';
import 'services/ai/ai_provider.dart';
import 'services/ai/ai_service.dart';
import 'services/ai/ai_step_executor.dart';
import 'services/ai/anthropic_provider.dart';
import 'services/ai/local_templates_provider.dart';
import 'services/ai/nl_workflow_parser.dart';
import 'services/ai/openai_compatible_provider.dart';
import 'services/connections/connection_manager.dart';
import 'services/execution/execution_service.dart';
import 'services/integrations/action_executors.dart';
import 'services/integrations/core_integrations.dart';
import 'services/integrations/integration.dart';
import 'services/integrations/whatsapp/business_whatsapp_adapter.dart';
import 'services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'services/integrations/whatsapp/whatsapp_integration.dart';
import 'services/integrations/whatsapp/whatsapp_models.dart';
import 'services/integrations/whatsapp/whatsapp_step_executor.dart';
import 'services/net/api_client.dart';
import 'services/notifications/notification_service.dart';
import 'services/scheduler/alarm_platform.dart';
import 'services/scheduler/android_alarm_bindings.dart';
import 'services/scheduler/scheduler_service.dart';
import 'services/settings/settings_service.dart';

/// Composition root (spec §37).
///
/// One place knows how the pieces fit together; everything else receives its
/// dependencies. `bootstrapForBackground` builds the same graph inside an
/// AlarmManager isolate, which is why no service here may depend on a widget,
/// a `BuildContext` or the UI isolate's state.
class AppServices {
  AppServices._({
    required this.database,
    required this.secrets,
    required this.apiClient,
    required this.platform,
    required this.settings,
    required this.workflows,
    required this.executions,
    required this.approvals,
    required this.connectionRepository,
    required this.contacts,
    required this.variables,
    required this.ai,
    required this.nlParser,
    required this.whatsapp,
    required this.integrations,
    required this.connections,
    required this.executors,
    required this.engine,
    required this.scheduler,
    required this.execution,
    required this.notifications,
    required this.calculator,
  });

  final AppDatabase database;
  final SecretStore secrets;
  final ApiClient apiClient;
  final AlarmPlatform platform;
  final SettingsService settings;

  final WorkflowRepository workflows;
  final ExecutionRepository executions;
  final ApprovalRepository approvals;
  final ConnectionRepository connectionRepository;
  final ContactRepository contacts;
  final VariableRepository variables;

  final AiService ai;
  final NaturalLanguageWorkflowParser nlParser;
  final WhatsAppIntegration whatsapp;
  final IntegrationRegistry integrations;
  final ConnectionManager connections;

  final StepExecutorRegistry executors;
  final WorkflowEngine engine;
  final SchedulerService scheduler;
  final ExecutionService execution;
  final NotificationService notifications;
  final ScheduleCalculator calculator;

  static final Logger _log = Logger.withTag('BOOT');

  /// Full startup for the UI isolate.
  static Future<AppServices> bootstrap({
    AppDatabase? database,
    SecretStore? secrets,
    ApiClient? apiClient,
    AlarmPlatform? platform,
    bool enableAlarmManager = true,
  }) async {
    tzdata.initializeTimeZones();
    final String? deviceZone = await _detectDeviceTimeZone(platform);
    if (deviceZone != null) ScheduleCalculator.setDeviceLocation(deviceZone);

    final AppServices services = await _build(
      database: database,
      secrets: secrets,
      apiClient: apiClient,
      platform: platform,
      enableAlarmManager: enableAlarmManager,
    );
    await services.settings.load();
    await services._loadAiSettings();
    return services;
  }

  /// Startup inside a background isolate spawned by AlarmManager.
  static Future<AppServices> bootstrapForBackground() async {
    _log.info('Bootstrapping background isolate');
    // `bootstrap` already loaded the pause flag, so the engine's global
    // gate is correct before the first step runs.
    return bootstrap();
  }

  static Future<String?> _detectDeviceTimeZone(AlarmPlatform? platform) async {
    try {
      return await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      try {
        return await platform?.deviceTimeZone();
      } catch (_) {
        return null;
      }
    }
  }

  static Future<AppServices> _build({
    AppDatabase? database,
    SecretStore? secrets,
    ApiClient? apiClient,
    AlarmPlatform? platform,
    required bool enableAlarmManager,
  }) async {
    final AppDatabase db = database ?? await AppDatabase.open();
    final SecretStore secretStore = secrets ?? SecureSecretStore();
    final ApiClient api = apiClient ?? HttpApiClient();

    final AlarmPlatform alarmPlatform = platform ??
        (enableAlarmManager && defaultTargetPlatform == TargetPlatform.android
            ? AndroidAlarmBindings.create()
            : const UnavailableAlarmPlatform());

    // --- Repositories --------------------------------------------------------
    final SettingsRepository settingsRepo = SettingsRepository(db);
    final WorkflowRepository workflowRepo = WorkflowRepository(db);
    final ExecutionRepository executionRepo = ExecutionRepository(db);
    final ApprovalRepository approvalRepo = ApprovalRepository(db);
    final ConnectionRepository connectionRepo = ConnectionRepository(db);
    final ContactRepository contactRepo = ContactRepository(db);
    final VariableRepository variableRepo = VariableRepository(db);

    // --- Settings ------------------------------------------------------------
    final SettingsService settings = SettingsService(
      repository: settingsRepo,
      variables: variableRepo,
      platform: alarmPlatform,
    );

    // --- AI ------------------------------------------------------------------
    final AiProviderRegistry aiProviders = AiProviderRegistry(<AiProvider>[
      OpenAiCompatibleProvider(apiClient: api, secrets: secretStore),
      AnthropicProvider(apiClient: api, secrets: secretStore),
      const LocalTemplatesProvider(),
    ]);
    final AiService ai = AiService(
      registry: aiProviders,
      secrets: secretStore,
      initial: const AiSettings(),
    );

    // --- Integrations --------------------------------------------------------
    final PersonalWhatsAppAdapter personal = PersonalWhatsAppAdapter();
    final BusinessWhatsAppAdapter business = BusinessWhatsAppAdapter(
      apiClient: api,
      secrets: secretStore,
      configProvider: () async => WhatsAppBusinessConfig(
        phoneNumberId: await settingsRepo.get('whatsapp.business.phone_number_id') ?? '',
        apiVersion: await settingsRepo.get('whatsapp.business.api_version') ??
            WhatsAppBusinessConfig.defaultApiVersion,
        defaultTemplateLanguage:
            await settingsRepo.get('whatsapp.business.language') ?? 'en_US',
      ),
    );

    final WhatsAppIntegration whatsapp = WhatsAppIntegration(
      personalAdapter: personal,
      businessAdapter: business,
      activeTypeProvider: () async =>
          WhatsAppAccountType.fromWire(await settingsRepo.get('whatsapp.account_type')),
      activeTypeWriter: (WhatsAppAccountType? type) async {
        if (type == null) {
          await settingsRepo.remove('whatsapp.account_type');
        } else {
          await settingsRepo.set('whatsapp.account_type', type.wire);
        }
      },
    );

    final NotificationService notifications = NotificationService(platform: alarmPlatform);

    final IntegrationRegistry integrations = IntegrationRegistry(<Integration>[
      whatsapp,
      AiIntegration(ai: ai),
      NotificationIntegration(notifications: notifications, platform: alarmPlatform),
      const HttpIntegration(),
      WebhookIntegration(endpointProvider: () async => settingsRepo.get('webhook.endpoint')),
    ]);

    final ConnectionManager connections = ConnectionManager(
      registry: integrations,
      repository: connectionRepo,
    );

    // --- Engine --------------------------------------------------------------
    final StepExecutorRegistry executors = StepExecutorRegistry(<StepExecutor>[
      WhatsAppStepExecutor(integration: whatsapp, contacts: contactRepo),
      AiStepExecutor(ai: ai),
      NotificationStepExecutor(
        poster: ({required String title, required String body, String? payload}) =>
            notifications.show(
          title: title,
          body: body,
          channel: NotificationChannels.workflow,
          payload: payload,
        ),
        permissionCheck: () => alarmPlatform.notificationsPermitted,
      ),
      HttpStepExecutor(apiClient: api),
      WebhookStepExecutor(apiClient: api),
      ClipboardStepExecutor(
        copy: (String text) async => Clipboard.setData(ClipboardData(text: text)),
      ),
      OpenUrlStepExecutor(
        open: (Uri uri) => launcher.launchUrl(uri, mode: launcher.LaunchMode.externalApplication),
        canOpen: launcher.canLaunchUrl,
      ),
      const SetVariableStepExecutor(),
    ]);

    final ScheduleCalculator calculator = ScheduleCalculator();
    final SqlIdempotencyStore idempotency = SqlIdempotencyStore(db);
    final SqlEngineSink sink =
        SqlEngineSink(executions: executionRepo, approvals: approvalRepo);

    final WorkflowEngine engine = WorkflowEngine(
      registry: executors,
      idempotency: idempotency,
      state: settings,
      sink: sink,
      scheduleCalculator: calculator,
      delayHandler: (DelayRequest request) async {
        // A wait that outlives a background isolate is handed back to the OS
        // scheduler; short waits stay in-process so the run finishes in one go.
        if (request.isBackground || request.duration > const Duration(minutes: 2)) {
          return DelayDecision.defer;
        }
        return DelayDecision.sleep;
      },
    );

    final SchedulerService scheduler = SchedulerService(
      platform: alarmPlatform,
      calculator: calculator,
      workflows: workflowRepo,
    );

    final ExecutionService execution = ExecutionService(
      engine: engine,
      workflows: workflowRepo,
      executions: executionRepo,
      approvals: approvalRepo,
      scheduler: scheduler,
      notifications: notifications,
      calculator: calculator,
      pausedProvider: () async => settings.isPaused,
    );

    notifications.onTap = (String? payload) {
      _log.info('Notification tapped: $payload');
    };

    return AppServices._(
      database: db,
      secrets: secretStore,
      apiClient: api,
      platform: alarmPlatform,
      settings: settings,
      workflows: workflowRepo,
      executions: executionRepo,
      approvals: approvalRepo,
      connectionRepository: connectionRepo,
      contacts: contactRepo,
      variables: variableRepo,
      ai: ai,
      nlParser: NaturalLanguageWorkflowParser(ai: ai),
      whatsapp: whatsapp,
      integrations: integrations,
      connections: connections,
      executors: executors,
      engine: engine,
      scheduler: scheduler,
      execution: execution,
      notifications: notifications,
      calculator: calculator,
    );
  }

  /// Reads AI configuration out of the settings table into [AiService].
  ///
  /// The key itself is never loaded into memory here — only whether one exists.
  Future<void> _loadAiSettings() async {
    final String? providerId = await settings.repository.get(SettingKeys.aiProviderId);
    final String? model = await settings.repository.get(SettingKeys.aiModel);
    final String? temperature = await settings.repository.get(SettingKeys.aiTemperature);
    final String? baseUrl = await settings.repository.get(SettingKeys.aiBaseUrl);
    final bool keyStored = await secrets.contains(SecretKeys.aiApiKey);

    ai.updateSettings(AiSettings(
      providerId: AiProviderId.fromWire(providerId),
      model: model ?? '',
      temperature: double.tryParse(temperature ?? '') ?? 0.7,
      baseUrl: baseUrl ?? 'https://api.openai.com/v1',
      apiKeyStored: keyStored,
    ));
    _log.info('AI provider: ${ai.settings.providerId.wire}');
  }

  /// Persists AI settings and refreshes the provider configuration.
  Future<void> saveAiSettings(AiSettings value) async {
    await settings.repository.set(SettingKeys.aiProviderId, value.providerId.wire);
    await settings.repository.set(SettingKeys.aiModel, value.model);
    await settings.repository.set(SettingKeys.aiTemperature, '${value.temperature}');
    await settings.repository.set(SettingKeys.aiBaseUrl, value.baseUrl);

    final AiProvider? provider = ai.registry.byId(value.providerId);
    if (provider is OpenAiCompatibleProvider) {
      ai.registry.register(OpenAiCompatibleProvider(
        apiClient: apiClient,
        secrets: secrets,
        baseUrl: value.baseUrl,
        model: value.model.isEmpty ? provider.defaultModel : value.model,
        temperature: value.temperature,
      ));
    } else if (provider is AnthropicProvider) {
      ai.registry.register(AnthropicProvider(
        apiClient: apiClient,
        secrets: secrets,
        model: value.model.isEmpty ? provider.defaultModel : value.model,
        temperature: value.temperature,
      ));
    }

    ai.updateSettings(value.copyWith(apiKeyStored: await secrets.contains(SecretKeys.aiApiKey)));
    await connections.refresh(IntegrationIds.ai);
  }

  /// Stores Business API configuration. The token goes to secure storage;
  /// only the non-secret identifiers are written to SQLite.
  Future<void> saveWhatsAppBusinessConfig({
    required String phoneNumberId,
    required String accessToken,
    String apiVersion = WhatsAppBusinessConfig.defaultApiVersion,
    String templateLanguage = 'en_US',
  }) async {
    await settings.repository.set('whatsapp.business.phone_number_id', phoneNumberId.trim());
    await settings.repository.set('whatsapp.business.api_version', apiVersion.trim());
    await settings.repository.set('whatsapp.business.language', templateLanguage.trim());
    if (accessToken.trim().isNotEmpty) {
      await secrets.write(SecretKeys.whatsappBusinessToken, accessToken.trim());
    }
    await whatsapp.businessAdapter.configure(WhatsAppBusinessConfig(
      phoneNumberId: phoneNumberId.trim(),
      apiVersion: apiVersion.trim(),
      defaultTemplateLanguage: templateLanguage.trim(),
    ));
    await whatsapp.selectType(WhatsAppAccountType.business);
    await connections.refresh(IntegrationIds.whatsapp);
  }

  Future<void> shutdown() async {
    await engine.dispose();
    await database.close();
    _log.info('Services shut down');
  }
}
