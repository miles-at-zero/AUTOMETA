import 'dart:convert';

import 'package:autometa/business/business_api.dart';
import 'package:autometa/ui/screens/business/flow_editor_screen.dart';
import 'package:autometa/ui/screens/business/flows_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('BusinessApi sends bearer token and parses JSON', () async {
    late http.Request seen;
    final BusinessApi api = BusinessApi(
      baseUrl: 'https://srv.example/',
      token: 'tok',
      client: MockClient((http.Request r) async {
        seen = r;
        return http.Response(jsonEncode(<String, dynamic>{'ok': true, 'n': 3}), 200);
      }),
    );
    final Json r = await api.post('/flows/x/test', <String, dynamic>{'messages': <String>['hi']});
    expect(seen.url.toString(), 'https://srv.example/flows/x/test');
    expect(seen.headers['authorization'], 'Bearer tok');
    expect(jsonDecode(seen.body), <String, dynamic>{'messages': <String>['hi']});
    expect(intOf(r['n']), 3);
  });

  test('402 becomes an upgrade error with the required plan', () async {
    final BusinessApi api = BusinessApi(
      baseUrl: 'https://srv.example',
      client: MockClient((_) async => http.Response(jsonEncode(<String, dynamic>{'error': 'Team is a Pro feature', 'requiredPlan': 'pro'}), 402)),
    );
    try {
      await api.get('/team');
      fail('should throw');
    } on BusinessApiException catch (e) {
      expect(e.isUpgrade, isTrue);
      expect(e.requiredPlan, 'pro');
      expect(e.message, 'Team is a Pro feature');
    }
  });

  test('validation errors are listed', () async {
    final BusinessApi api = BusinessApi(
      baseUrl: 'https://srv.example',
      client: MockClient((_) async => http.Response(jsonEncode(<String, dynamic>{'error': 'a', 'errors': <String>['a', 'b']}), 422)),
    );
    await expectLater(api.get('/x'), throwsA(isA<BusinessApiException>().having((BusinessApiException e) => e.errors, 'errors', <String>['a', 'b'])));
  });

  test('network failure has a friendly message', () async {
    final BusinessApi api = BusinessApi(baseUrl: 'https://srv.example', client: MockClient((_) async => throw Exception('dns')));
    await expectLater(api.get('/me'), throwsA(isA<BusinessApiException>().having((BusinessApiException e) => e.status, 'status', 0)));
  });

  test('editor summaries describe steps in plain language', () {
    expect(kindOf(<String, dynamic>{'type': 'condition', 'rules': <dynamic>[<String, dynamic>{'if': <String, dynamic>{'kind': 'business_hours', 'value': 'open'}}]}).label, 'Business hours check');
    expect(stepSummary(<String, dynamic>{'type': 'question', 'text': 'How many?', 'saveAs': 'quantity'}), contains('{{quantity}}'));
    expect(stepSummary(<String, dynamic>{'type': 'delay', 'minutes': 15}), '15 minutes');
    expect(triggerLabel(<String, dynamic>{'type': 'keyword', 'keywords': <String>['menu', 'order']}), contains('menu, order'));
    expect(ruleText(<String, dynamic>{'kind': 'var', 'var': 'fulfilment', 'op': 'eq', 'value': 'delivery'}), 'If fulfilment eq delivery');
  });

  test('JSON helpers tolerate wrong shapes', () {
    expect(asMap(null), isEmpty);
    expect(asList('x'), isEmpty);
    expect(asStrings(<dynamic>[1, 'a']), <String>['1', 'a']);
    expect(intOf('12'), 12);
  });
}
