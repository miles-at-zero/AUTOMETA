import 'package:autometa/domain/health/guardian.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
import 'package:autometa/core/theme/autometa_theme.dart';
import 'package:autometa/ui/widgets/guardian_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final DateTime now = DateTime(2026, 10, 7, 12);

  Workflow wf(String id, {bool cloud = false, bool enabled = true}) => Workflow(
        id: id,
        name: 'Flow $id',
        enabled: enabled,
        executionMode: cloud ? ExecutionMode.cloud : ExecutionMode.onDevice,
        trigger: const ScheduleTrigger(timeOfDay: '07:00'),
        steps: const <WorkflowStep>[WhatsAppStep(id: 's', recipient: 'Dad', message: 'Hi')],
      );

  int n = 0;
  ExecutionRecord rec(String workflowId, int hoursAgo, ExecutionStatus st, {String? reason, bool dry = false}) {
    final DateTime at = now.subtract(Duration(hours: hoursAgo));
    n++;
    return ExecutionRecord(
      id: 'r$n', workflowId: workflowId, workflowName: 'x', idempotencyKey: 'k$n',
      scheduledFor: at, startedAt: at, finishedAt: at, status: st, failureReason: reason, dryRun: dry,
    );
  }

  group('Guardian: on-device findings', () {
    test('no runs / healthy runs -> no findings (nothing invented)', () {
      expect(GuardianFinding.forDevice(<Workflow>[wf('a')], <ExecutionRecord>[], now), isEmpty);
      expect(
        GuardianFinding.forDevice(<Workflow>[wf('a')], <ExecutionRecord>[rec('a', 1, ExecutionStatus.success)], now),
        isEmpty,
      );
    });

    test('3 failures in a row -> one critical, certain finding with the real reason', () {
      final List<GuardianFinding> fs = GuardianFinding.forDevice(<Workflow>[wf('a')], <ExecutionRecord>[
        rec('a', 1, ExecutionStatus.failed, reason: 'No internet'),
        rec('a', 2, ExecutionStatus.failed, reason: 'No internet'),
        rec('a', 3, ExecutionStatus.failed, reason: 'No internet'),
      ], now);
      expect(fs, hasLength(1));
      expect(fs.single.severity, FindingSeverity.critical);
      expect(fs.single.certain, isTrue);
      expect(fs.single.isCloud, isFalse);
      expect(fs.single.workflowId, 'a');
      expect(fs.single.body, 'Last error: No internet');
      expect(fs.single.title, 'Failed 3 times in a row');
      expect(fs.single.actionLabel, 'View automation');
    });

    test('Cloud and disabled automations are never judged from device records', () {
      final List<ExecutionRecord> bad = <ExecutionRecord>[
        rec('c', 1, ExecutionStatus.failed), rec('c', 2, ExecutionStatus.failed), rec('c', 3, ExecutionStatus.failed),
        rec('d', 1, ExecutionStatus.failed),
      ];
      expect(GuardianFinding.forDevice(<Workflow>[wf('c', cloud: true), wf('d', enabled: false)], bad, now), isEmpty);
    });

    test('dry runs are tests, not history', () {
      expect(
        GuardianFinding.forDevice(<Workflow>[wf('a')], <ExecutionRecord>[rec('a', 1, ExecutionStatus.failed, dry: true)], now),
        isEmpty,
      );
    });
  });

  group('Guardian: Cloud report parsing', () {
    test('maps severity/certainty, keeps links, drops malformed rows', () {
      final List<GuardianFinding> fs = GuardianFinding.fromCloudReport(<String, dynamic>{
        'findings': <Object?>[
          <String, dynamic>{'kind': 'overdue_schedule', 'severity': 'attention', 'certainty': 'unusual', 'title': 'A scheduled run looks overdue', 'body': 'b', 'automationId': 'srv1', 'automationName': 'Report'},
          <String, dynamic>{'kind': 'connection_attention', 'severity': 'critical', 'certainty': 'certain', 'title': 'Gmail needs to be reconnected', 'body': 'Token revoked', 'connectionId': 'c1'},
          <String, dynamic>{'severity': 'critical'}, // no title -> dropped
          'garbage',
        ],
      });
      expect(fs, hasLength(2));
      expect(fs[0].certain, isFalse, reason: 'heuristics are never presented as fact');
      expect(fs[0].cloudAutomationId, 'srv1');
      expect(fs[0].isCloud, isTrue);
      expect(fs[1].connectionId, 'c1');
      expect(GuardianFinding.sorted(fs).first.severity, FindingSeverity.critical);
    });

    test('missing or malformed report -> empty, not an error', () {
      expect(GuardianFinding.fromCloudReport(<String, dynamic>{}), isEmpty);
      expect(GuardianFinding.fromCloudReport(<String, dynamic>{'findings': 'nope'}), isEmpty);
    });
  });

  group('Home: Needs your attention (GuardianFindingsView)', () {
    GuardianFinding f(String kind, FindingSeverity sev, {String? wf, String? cloud, String? conn, bool certain = true, String name = 'X', String? action}) =>
        GuardianFinding(kind: kind, severity: sev, certain: certain, title: 'T-$kind', body: 'B-$kind', why: 'W-$kind',
            isCloud: wf == null, automationName: conn == null ? name : null, workflowId: wf, cloudAutomationId: cloud, connectionId: conn, actionLabel: action);

    Future<void> pump(WidgetTester tester, List<GuardianFinding> fs, {bool cloudGap = false, ValueChanged<GuardianFinding>? onOpen}) async {
      tester.view.physicalSize = const Size(360 * 3, 1600 * 3); // narrow phone
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: AutometaTheme.dark,
        home: Scaffold(body: SingleChildScrollView(child: GuardianFindingsView(findings: fs, cloudGap: cloudGap, onOpen: onOpen ?? (_) {}))),
      ));
    }

    testWidgets('empty: calm headline, no invented findings', (WidgetTester tester) async {
      await pump(tester, const <GuardianFinding>[]);
      expect(find.text('Nothing needs your attention right now.'), findsOneWidget);
      expect(find.byKey(const Key('guardian.cloudGap')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cloud not checked: says so instead of "all clear"', (WidgetTester tester) async {
      await pump(tester, const <GuardianFinding>[], cloudGap: true);
      expect(find.text('Nothing needs attention on this device.'), findsOneWidget);
      expect(find.byKey(const Key('guardian.cloudGap')), findsOneWidget);
    });

    testWidgets('renders ordered findings, caps the list, explains each one', (WidgetTester tester) async {
      final List<GuardianFinding> fs = GuardianFinding.sorted(<GuardianFinding>[
        f('looks_inactive', FindingSeverity.info, cloud: 's4', certain: false),
        f('missed_schedule', FindingSeverity.attention, cloud: 's3'),
        f('connection_attention', FindingSeverity.critical, conn: 'c1', action: 'Reconnect'),
        f('repeated_failures', FindingSeverity.critical, wf: 'w1', action: 'View automation'),
      ]);
      expect(fs.map((GuardianFinding x) => x.kind), <String>['repeated_failures', 'connection_attention', 'missed_schedule', 'looks_inactive']);
      await pump(tester, fs);
      expect(find.text('4 things need your attention'), findsOneWidget);
      expect(find.text('T-repeated_failures'), findsOneWidget);
      expect(find.text('W-repeated_failures'), findsOneWidget, reason: 'every finding says why it matters');
      expect(find.text('📱 On this device'), findsOneWidget);
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.text('T-looks_inactive'), findsNothing, reason: 'Home shows at most 3');
      expect(find.text('+ 1 more. Open each automation to review.'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'no overflow at 360dp');
    });

    testWidgets('heuristic findings are marked as possibly expected', (WidgetTester tester) async {
      await pump(tester, <GuardianFinding>[f('looks_inactive', FindingSeverity.info, cloud: 's4', certain: false)]);
      expect(find.text('Looks unusual. This may be expected.'), findsOneWidget);
    });

    testWidgets('actions pass the real ids of the affected automation / connection', (WidgetTester tester) async {
      final List<GuardianFinding> opened = <GuardianFinding>[];
      await pump(tester, <GuardianFinding>[
        f('repeated_failures', FindingSeverity.critical, wf: 'w1', action: 'View automation'),
        f('connection_attention', FindingSeverity.critical, conn: 'c9', action: 'Reconnect'),
      ], onOpen: opened.add);
      await tester.tap(find.byKey(const Key('guardian.action.repeated_failures')));
      await tester.tap(find.byKey(const Key('guardian.action.connection_attention')));
      expect(opened.map((GuardianFinding x) => x.workflowId ?? x.connectionId), <String>['w1', 'c9']);
    });

    testWidgets('long error text wraps without overflow on a narrow phone', (WidgetTester tester) async {
      await pump(tester, <GuardianFinding>[
        GuardianFinding(kind: 'repeated_failures', severity: FindingSeverity.critical, certain: true,
            title: 'Failed 3 times in a row', body: 'Last error: ${'Telegram responded 403 Forbidden: bot was blocked by the user ' * 4}',
            why: 'Repeated failures usually mean something changed.', isCloud: true,
            automationName: 'A very long automation name that keeps going and going for testing wrap', actionLabel: 'View automation'),
      ]);
      expect(tester.takeException(), isNull);
    });
  });

  group('Cloud report: v1 fields', () {
    test('why, action label and detectedAt are parsed', () {
      final GuardianFinding g = GuardianFinding.fromCloudReport(<String, dynamic>{
        'findings': <Object?>[
          <String, dynamic>{'kind': 'missed_schedule', 'severity': 'attention', 'certainty': 'certain', 'title': 'Scheduled run was missed',
            'why': 'It was expected to run.', 'body': 'b', 'automationId': 'a1', 'detectedAt': 1000,
            'action': <String, dynamic>{'type': 'open_automation', 'id': 'a1', 'label': 'View automation'}},
        ],
      }).single;
      expect(g.why, 'It was expected to run.');
      expect(g.actionLabel, 'View automation');
      expect(g.detectedAt, DateTime.fromMillisecondsSinceEpoch(1000));
    });
  });
}
