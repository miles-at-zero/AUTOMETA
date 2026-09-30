import 'package:autometa/core/security/secret_store.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/services/ai/ai_provider.dart';
import 'package:autometa/services/ai/ai_service.dart';
import 'package:autometa/services/ai/local_templates_provider.dart';
import 'package:autometa/services/ai/nl_workflow_parser.dart';
import 'package:autometa/services/ai/openai_compatible_provider.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeApi extends ApiClient {
  FakeApi(this.response);
  final ApiResponse response;
  final List<ApiRequest> calls = <ApiRequest>[];
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    calls.add(request);
    return response;
  }
}

AiService localAi() => AiService(
      registry: AiProviderRegistry(<AiProvider>[const LocalTemplatesProvider()]),
      secrets: InMemorySecretStore(),
      initial: const AiSettings(),
    );

void main() {
  int n = 0;
  final NaturalLanguageWorkflowParser parser = NaturalLanguageWorkflowParser(ai: localAi(), idGenerator: () => 'id${n++}');

  test('"Every morning at 7, send Dad a nice WhatsApp greeting."', () async {
    final ParsedWorkflow p = await parser.parse('Every morning at 7, send Dad a nice WhatsApp greeting.');
    final ScheduleTrigger t = p.workflow.trigger as ScheduleTrigger;
    expect(t.timeOfDay, '07:00');
    expect(t.repeat, ScheduleRepeat.daily);
    final WhatsAppStep s = p.workflow.steps.single as WhatsAppStep;
    expect(s.recipient, 'Dad');
    expect(s.message, 'Good morning Dad');
    expect(s.mode, WhatsAppMode.prepare);
    expect(p.workflow.enabled, isFalse, reason: 'AI must never silently activate');
    expect(p.usedAi, isFalse);
  });

  test('Sunday 18:00 AI summary → notification (acceptance)', () async {
    final ParsedWorkflow p = await parser.parse('Every Sunday at 18:00 generate an AI summary and show me a notification');
    final ScheduleTrigger t = p.workflow.trigger as ScheduleTrigger;
    expect(t.timeOfDay, '18:00');
    expect(t.effectiveWeekdays, <int>{7});
    expect(p.workflow.steps.first, isA<AiStep>());
    expect(p.workflow.steps.last, isA<NotificationStep>());
    expect((p.workflow.steps.last as NotificationStep).body, '{{ai_output}}');
  });

  test('weekday briefing', () async {
    final ParsedWorkflow p = await parser.parse('Every weekday at 8 give me a short AI briefing.');
    expect((p.workflow.trigger as ScheduleTrigger).repeat, ScheduleRepeat.weekdays);
    expect((p.workflow.trigger as ScheduleTrigger).timeOfDay, '08:00');
  });

  test('pm times and missing time assumption', () async {
    final ParsedWorkflow pm = await parser.parse('remind me at 8pm to drink water');
    expect((pm.workflow.trigger as ScheduleTrigger).timeOfDay, '20:00');
    final ParsedWorkflow none = await parser.parse('Every Sunday remind me to review my projects.');
    expect(none.assumptions.join(), contains('No time given'));
    expect((none.workflow.steps.single as NotificationStep).body, 'Review my projects.');
  });

  test('local templates are labelled, deterministic and length-bounded', () async {
    const LocalTemplatesProvider p = LocalTemplatesProvider();
    final AiCompletion a = await p.complete(const AiPrompt(task: AiTask.generate, instruction: 'morning message for dad', maxLength: 60));
    final AiCompletion b = await p.complete(const AiPrompt(task: AiTask.generate, instruction: 'morning message for dad', maxLength: 60));
    expect(a.text, b.text);
    expect(a.text.length, lessThanOrEqualTo(61));
    expect(a.providerId, AiProviderId.localTemplates);
  });

  test('AI service refuses a key-requiring provider with no key', () async {
    final AiService ai = AiService(
      registry: AiProviderRegistry(<AiProvider>[OpenAiCompatibleProvider(apiClient: FakeApi(const ApiResponse(statusCode: 200, body: '{}')), secrets: InMemorySecretStore())]),
      secrets: InMemorySecretStore(),
      initial: const AiSettings(providerId: AiProviderId.openAiCompatible),
    );
    expect(() => ai.complete(const AiPrompt(task: AiTask.generate, instruction: 'x')), throwsA(isA<AiProviderException>()));
  });

  test('OpenAI-compatible provider parses a completion and sends a bearer header', () async {
    final FakeApi api = FakeApi(const ApiResponse(statusCode: 200, body: '{"model":"m","choices":[{"message":{"content":"Good morning!"}}]}'));
    final OpenAiCompatibleProvider p = OpenAiCompatibleProvider(apiClient: api, secrets: InMemorySecretStore(<String, String>{'ai.api_key': 'sk-test-123456'}));
    final AiCompletion c = await p.complete(const AiPrompt(task: AiTask.generate, instruction: 'hi'));
    expect(c.text, 'Good morning!');
    expect(api.calls.single.headers['Authorization'], 'Bearer sk-test-123456');
    expect(api.calls.single.describe(), isNot(contains('sk-test')), reason: 'keys never reach logs');
  });
}
