import 'dart:convert';

import 'package:autometa/core/security/secret_store.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/services/connections/connection_state.dart';
import 'package:autometa/services/integrations/integration.dart';
import 'package:autometa/services/integrations/whatsapp/business_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/personal_whatsapp_adapter.dart';
import 'package:autometa/services/integrations/whatsapp/whatsapp_models.dart';
import 'package:autometa/services/net/api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whatsapp_auto_send/whatsapp_auto_send.dart';

class FakeApi extends ApiClient {
  FakeApi(this.response);
  ApiResponse response;
  final List<ApiRequest> calls = <ApiRequest>[];
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    calls.add(request);
    return response;
  }
}

void main() {
  group('personal auto-send', () {
    const AutoSendServiceStatus on = AutoSendServiceStatus(enabled: true, running: true, whatsappPackage: 'com.whatsapp');
    PersonalWhatsAppAdapter adapter(AutoSendResult result, {List<String>? log}) => PersonalWhatsAppAdapter(
          probe: (_) async => true,
          opener: (_) async => true,
          autoSendStatus: () async => on,
          autoSender: (String phone, String text) async {
            log?.add('$phone|$text');
            return result;
          },
        );

    test('confirmed tap is reported as sent from phone', () async {
      final List<String> log = <String>[];
      final PersonalWhatsAppAdapter a = adapter(const AutoSendResult(AutoSendStatus.sent), log: log);
      expect(await a.canSendNow(), isTrue);
      final WhatsAppSendOutcome o =
          await a.deliver(mode: WhatsAppMode.send, phoneNumberDigits: '+234 800 000 0000', body: 'Good morning Dad');
      expect(o.state, WhatsAppDeliveryState.sentFromPhone);
      expect(o.succeeded, isTrue);
      expect(log, <String>['2348000000000|Good morning Dad']);
    });

    test('locked phone is a retriable failure, never a success', () async {
      final WhatsAppSendOutcome o = await adapter(const AutoSendResult(AutoSendStatus.locked, 'Phone is locked'))
          .deliver(mode: WhatsAppMode.send, phoneNumberDigits: '234800', body: 'x');
      expect(o.state, WhatsAppDeliveryState.failed);
      expect(o.succeeded, isFalse);
      expect(o.retriable, isTrue);
    });

    test('unconfirmed tap is not retried (could duplicate)', () async {
      final WhatsAppSendOutcome o = await adapter(const AutoSendResult(AutoSendStatus.unconfirmed))
          .deliver(mode: WhatsAppMode.send, phoneNumberDigits: '234800', body: 'x');
      expect(o.state, WhatsAppDeliveryState.failed);
      expect(o.retriable, isFalse);
    });

    test('availability says auto-send is on', () async {
      final IntegrationAvailability av = await adapter(const AutoSendResult(AutoSendStatus.sent)).check();
      expect(av.status, ConnectionStatus.connected);
      expect(av.label, contains('auto-send'));
    });
  });

  group('personal', () {
    test('builds the official wa.me link with encoded text', () {
      final Uri uri = PersonalWhatsAppAdapter(probe: (_) async => true, opener: (_) async => true)
          .conversationUri(phoneNumberDigits: '+234 800 000 0000', text: 'Good morning Dad')!;
      expect(uri.host, 'wa.me');
      expect(uri.path, '/2348000000000');
      expect(uri.queryParameters['text'], 'Good morning Dad');
    });

    test('does not send automatically while auto-send is off', () async {
      final PersonalWhatsAppAdapter a = PersonalWhatsAppAdapter(probe: (_) async => true, opener: (_) async => true);
      final WhatsAppSendOutcome o = await a.deliver(mode: WhatsAppMode.send, phoneNumberDigits: '234800', body: 'x');
      expect(o.state, WhatsAppDeliveryState.notSupported);
      expect(a.capabilities.canSendAutomatically, isFalse);
    });

    test('prepare hands off to the user and is NOT a confirmed delivery', () async {
      Uri? opened;
      final PersonalWhatsAppAdapter a = PersonalWhatsAppAdapter(probe: (_) async => true, opener: (Uri u) async {
        opened = u;
        return true;
      });
      final WhatsAppSendOutcome o = await a.deliver(mode: WhatsAppMode.prepare, phoneNumberDigits: '2348000000000', body: 'hi');
      expect(o.state, WhatsAppDeliveryState.handedToUser);
      expect(o.state.isConfirmedDelivery, isFalse);
      expect(opened, isNotNull);
    });

    test('reports unavailable when WhatsApp is not installed', () async {
      final IntegrationAvailability av = await PersonalWhatsAppAdapter(probe: (_) async => false).check();
      expect(av.status, ConnectionStatus.unavailable);
      expect(av.capabilities, isEmpty);
    });

    test('capabilities shown only include what works', () async {
      final IntegrationAvailability av = await PersonalWhatsAppAdapter(probe: (_) async => true).check();
      expect(av.capabilities, containsAll(<String>['Open conversations', 'Prepare messages']));
      expect(av.capabilities, isNot(contains('API messaging')));
    });
  });

  group('business', () {
    BusinessWhatsAppAdapter make(FakeApi api, {String token = 'EAAtoken12345'}) => BusinessWhatsAppAdapter(
          apiClient: api,
          secrets: InMemorySecretStore(<String, String>{if (token.isNotEmpty) 'whatsapp.business.access_token': token}),
          configProvider: () async => const WhatsAppBusinessConfig(phoneNumberId: '1065'),
        );

    test('sends to the documented Cloud API endpoint and payload', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 200, body: '{"messages":[{"id":"wamid.X","message_status":"accepted"}]}'));
      final WhatsAppSendOutcome o = await make(api).deliver(mode: WhatsAppMode.send, phoneNumberDigits: '2348000000000', body: 'Good morning Dad');
      expect(o.state, WhatsAppDeliveryState.delivered);
      expect(o.messageId, 'wamid.X');
      final ApiRequest req = api.calls.single;
      expect(req.url, 'https://graph.facebook.com/${WhatsAppBusinessConfig.defaultApiVersion}/1065/messages');
      expect(req.headers['Authorization'], 'Bearer EAAtoken12345');
      final Map<String, dynamic> body = jsonDecode(req.body!) as Map<String, dynamic>;
      expect(body['messaging_product'], 'whatsapp');
      expect(body['type'], 'text');
      expect((body['text'] as Map<String, dynamic>)['body'], 'Good morning Dad');
    });

    test('templates use the template payload', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 200, body: '{"messages":[{"id":"w"}]}'));
      await make(api).deliver(mode: WhatsAppMode.send, phoneNumberDigits: '234', body: '', templateName: 'hello_world');
      final Map<String, dynamic> body = jsonDecode(api.calls.single.body!) as Map<String, dynamic>;
      expect(body['type'], 'template');
      expect((body['template'] as Map<String, dynamic>)['name'], 'hello_world');
    });

    test('Meta error is a failure, never a success', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 400, body: '{"error":{"message":"Template not approved","code":132001}}'));
      final WhatsAppSendOutcome o = await make(api).deliver(mode: WhatsAppMode.send, phoneNumberDigits: '234', body: 'x');
      expect(o.state, WhatsAppDeliveryState.failed);
      expect(o.reason, contains('Template not approved'));
    });

    test('missing token → needs configuration, no network call', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 200, body: '{}'));
      final IntegrationAvailability av = await make(api, token: '').check();
      expect(av.status, ConnectionStatus.needsConfiguration);
      expect(api.calls, isEmpty);
    });

    test('rejected token → error, not connected', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 401, body: '{"error":{"message":"Invalid OAuth"}}'));
      expect((await make(api).check()).status, ConnectionStatus.error);
    });

    test('verified number → connected with business capabilities', () async {
      final FakeApi api = FakeApi(const ApiResponse(statusCode: 200, body: '{"verified_name":"Acme","quality_rating":"GREEN"}'));
      final IntegrationAvailability av = await make(api).check();
      expect(av.status, ConnectionStatus.connected);
      expect(av.capabilities, containsAll(<String>['API messaging', 'Delivery status']));
    });
  });
}
