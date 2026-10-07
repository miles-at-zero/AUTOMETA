import 'dart:async';

import 'package:autometa/business/business_api.dart';
import 'package:autometa/cloud/cloud_session.dart';
import 'package:autometa/core/theme/autometa_theme.dart';
import 'package:autometa/ui/screens/cloud_account_screen.dart';
import 'package:autometa/ui/screens/forgot_password_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

typedef _Request = Future<void> Function(String url, String email);

class _FakeCloudSession extends ChangeNotifier implements CloudSession {
  _FakeCloudSession(this.request);

  _Request request;
  int calls = 0;

  @override
  bool get signedIn => false;

  @override
  String get serverUrl => '';

  @override
  String get email => '';

  @override
  String get planName => '';

  @override
  String? get error => null;
  String? lastUrl;
  String? lastEmail;

  @override
  Future<void> forgotPassword(String url, String email) {
    calls++;
    lastUrl = url;
    lastEmail = email;
    return request(url, email);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const String serverUrl = 'https://cloud.example.test';

  Future<void> pump(
    WidgetTester tester,
    _FakeCloudSession session, {
    String email = '',
    double width = 360,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width * 3, 1800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<CloudSession>.value(
      value: session,
      child: MaterialApp(
        theme: AutometaTheme.dark,
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 1800), textScaler: TextScaler.linear(scale)),
          child: ForgotPasswordScreen(serverUrl: serverUrl, initialEmail: email),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('validates email locally and does not request recovery for invalid input', (WidgetTester tester) async {
    final _FakeCloudSession session = _FakeCloudSession((_, __) async {});
    await pump(tester, session);

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter your email address.'), findsOneWidget);
    expect(session.calls, 0);

    await tester.enterText(find.byKey(const Key('forgot.email')), 'not-an-email');
    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(session.calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the same generic success state and passes only server URL and email', (WidgetTester tester) async {
    final _FakeCloudSession session = _FakeCloudSession((_, __) async {});
    await pump(tester, session, email: 'ada@example.com');

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pumpAndSettle();

    expect(session.calls, 1);
    expect(session.lastUrl, serverUrl);
    expect(session.lastEmail, 'ada@example.com');
    expect(find.text("If an account exists for that email, you'll receive instructions to reset your password."), findsOneWidget);
    expect(find.text('Back to Sign In'), findsOneWidget);
    expect(find.byKey(const Key('forgot.email')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('submit disables while in flight and blocks duplicate requests', (WidgetTester tester) async {
    final Completer<void> pending = Completer<void>();
    final _FakeCloudSession session = _FakeCloudSession((_, __) => pending.future);
    await pump(tester, session, email: 'ada@example.com');

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pump();
    expect(session.calls, 1);
    final Finder button = find.descendant(
      of: find.byKey(const Key('forgot.submit')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNull);

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pump();
    expect(session.calls, 1);

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forgot.success')), findsOneWidget);
  });

  testWidgets('server/network errors are visible and the user can retry', (WidgetTester tester) async {
    int attempts = 0;
    final _FakeCloudSession session = _FakeCloudSession((_, __) async {
      attempts++;
      if (attempts == 1) throw BusinessApiException(0, 'Can\'t reach the server. Check your connection and try again.');
    });
    await pump(tester, session, email: 'ada@example.com');

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pumpAndSettle();
    expect(find.text('Can\'t reach the server. Check your connection and try again.'), findsOneWidget);
    expect(find.byKey(const Key('forgot.email')), findsOneWidget);

    await tester.tap(find.byKey(const Key('forgot.submit')));
    await tester.pumpAndSettle();
    expect(session.calls, 2);
    expect(find.byKey(const Key('forgot.success')), findsOneWidget);
  });

  testWidgets('form remains usable at 320/360dp and large text scales', (WidgetTester tester) async {
    for (final double width in <double>[320, 360]) {
      final _FakeCloudSession session = _FakeCloudSession((_, __) async {});
      await pump(tester, session, email: 'ada@example.com', width: width, scale: 1.8);
      expect(find.text('Back to Sign In'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'width=$width, large text');
    }
  });

  testWidgets('Cloud sign-in password can be shown/hidden and recovery returns to sign in', (WidgetTester tester) async {
    final _FakeCloudSession session = _FakeCloudSession((_, __) async {});
    await tester.pumpWidget(ChangeNotifierProvider<CloudSession>.value(
      value: session,
      child: MaterialApp(theme: AutometaTheme.dark, home: const CloudAccountScreen()),
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byKey(const Key('cloud.password'))).obscureText, isTrue);
    await tester.tap(find.byKey(const Key('cloud.passwordVisibility')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const Key('cloud.password'))).obscureText, isFalse);

    await tester.enterText(find.byKey(const Key('cloud.email')), 'ada@example.com');
    await tester.tap(find.byKey(const Key('cloud.forgotPassword')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('forgot.email')), findsOneWidget);
    expect(tester.widget<TextFormField>(find.byKey(const Key('forgot.email'))).controller!.text, 'ada@example.com');

    await tester.enterText(find.byKey(const Key('forgot.email')), 'new@example.com');
    await tester.tap(find.byKey(const Key('forgot.back')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('cloud.email'))).controller!.text, 'new@example.com');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Back to Sign In returns the edited email to the preceding sign-in route', (WidgetTester tester) async {
    final _FakeCloudSession session = _FakeCloudSession((_, __) async {});
    String? returnedEmail;
    tester.view.physicalSize = const Size(360 * 3, 1800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<CloudSession>.value(
      value: session,
      child: MaterialApp(
        theme: AutometaTheme.dark,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              key: const Key('test.openForgot'),
              onPressed: () async {
                returnedEmail = await Navigator.of(context).push<String>(MaterialPageRoute<String>(
                  builder: (_) => const ForgotPasswordScreen(serverUrl: serverUrl, initialEmail: 'first@example.com'),
                ));
              },
              child: const Text('Sign in'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('test.openForgot')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('forgot.email')), 'updated@example.com');
    await tester.tap(find.byKey(const Key('forgot.back')));
    await tester.pumpAndSettle();

    expect(returnedEmail, 'updated@example.com');
    expect(find.text('Sign in'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
