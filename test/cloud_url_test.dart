import 'package:autometa/cloud/cloud_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no default server is baked into plain builds (no localhost fallback)', () {
    expect(CloudSession.defaultServerUrl, isEmpty);
  });

  test('server address rules', () {
    expect(CloudSession.cleanUrl('api.example.com/'), 'https://api.example.com');
    expect(CloudSession.serverUrlProblem('https://api.example.com', release: true), isNull);
    expect(CloudSession.serverUrlProblem('http://192.168.1.5:8080', release: true), contains('https://'));
    expect(CloudSession.serverUrlProblem('http://192.168.1.5:8080', release: false), isNull);
    expect(CloudSession.serverUrlProblem('', release: false), isNotNull);
    expect(CloudSession.serverUrlProblem('ftp://x', release: false), isNotNull);
  });
}
