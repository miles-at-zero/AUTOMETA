// Control Room dashboard + Guardian Notification Center: the presentation
// layer is pure (data in, callbacks out), so it is driven directly here
// without the whole service graph.
//
// The layout cases matter: the dock and the dashboard are the two surfaces
// every user sees, and AUTOMETA ships to 320dp phones with 1.8x text.
import 'package:autometa/core/theme/autometa_theme.dart';
import 'package:autometa/core/theme/design_tokens.dart';
import 'package:autometa/domain/health/guardian.dart';
import 'package:autometa/domain/notifications/notification_center.dart';
import 'package:autometa/ui/screens/control_room_screen.dart';
import 'package:autometa/ui/screens/notification_center_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const List<ControlRoomConnection> connections = <ControlRoomConnection>[
  ControlRoomConnection(name: 'WhatsApp', detail: 'Connected', ok: true),
  ControlRoomConnection(name: 'Ai', detail: 'Not connected', ok: false),
];

const ControlRoomNextRun nextRun = ControlRoomNextRun(
  time: '7:30 AM',
  name: 'Morning text',
  preview: 'Good morning Dad',
  relative: 'in 3 h',
);

ControlRoomView dashboard({
  String greeting = 'Good morning',
  bool paused = false,
  int activeCount = 3,
  int failureCount = 0,
  int slotsToday = 4,
  int runsToday = 2,
  int attentionCount = 0,
  int criticalCount = 0,
  int unreadCount = 0,
  List<GuardianFinding> findings = const <GuardianFinding>[],
  bool cloudGap = false,
  bool notEnoughHistory = false,
  List<ControlRoomConnection> conns = connections,
  ControlRoomNextRun? next = nextRun,
  List<ControlRoomSlot> today = const <ControlRoomSlot>[],
  List<ControlRoomRun> recent = const <ControlRoomRun>[],
  List<ControlRoomApproval> approvals = const <ControlRoomApproval>[],
  VoidCallback onNewAutomation = _noop,
  VoidCallback onOpenNotifications = _noop,
  VoidCallback? onResume,
  ValueChanged<GuardianFinding>? onOpenFinding,
}) =>
    ControlRoomView(
      greeting: greeting,
      paused: paused,
      activeCount: activeCount,
      failureCount: failureCount,
      slotsToday: slotsToday,
      runsToday: runsToday,
      attentionCount: attentionCount,
      criticalCount: criticalCount,
      unreadCount: unreadCount,
      findings: findings,
      cloudGap: cloudGap,
      notEnoughHistory: notEnoughHistory,
      connections: conns,
      nextRun: next,
      today: today,
      recent: recent,
      approvals: approvals,
      onNewAutomation: onNewAutomation,
      onOpenNotifications: onOpenNotifications,
      onResume: onResume,
      onOpenFinding: onOpenFinding,
    );

void _noop() {}

Future<void> pumpAt(
  WidgetTester tester,
  Widget child, {
  double width = 360,
  double scale = 1,
}) async {
  tester.view.physicalSize = Size(width * 3, 1400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: AutometaTheme.dark,
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 1400), textScaler: TextScaler.linear(scale)),
      child: Scaffold(body: child),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  // ------------------------------------------------------ control room
  group('Control Room dashboard', () {
    testWidgets('shows the operational state when nothing needs attention',
        (WidgetTester tester) async {
      await pumpAt(tester, dashboard());
      expect(find.byKey(const Key('controlRoom.state')), findsOneWidget);
      expect(find.text('OPERATIONAL'), findsOneWidget);
      expect(find.text('All systems go'), findsOneWidget);
    });

    testWidgets('reports PAUSED and offers a way out', (WidgetTester tester) async {
      bool resumed = false;
      await pumpAt(
        tester,
        dashboard(paused: true, onResume: () => resumed = true),
      );
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.resume')), findsOneWidget);
      await tester.tap(find.byKey(const Key('controlRoom.resume')));
      await tester.pumpAndSettle();
      expect(resumed, isTrue);
    });

    testWidgets('escalates to ATTENTION with the critical count', (WidgetTester tester) async {
      await pumpAt(tester, dashboard(criticalCount: 2, attentionCount: 3));
      expect(find.text('ATTENTION'), findsOneWidget);
      expect(find.text('2 critical'), findsOneWidget);
    });

    testWidgets('escalates to ATTENTION for non-critical findings', (WidgetTester tester) async {
      await pumpAt(tester, dashboard(criticalCount: 0, attentionCount: 1));
      expect(find.text('ATTENTION'), findsOneWidget);
      expect(find.text('1 thing needs you'), findsOneWidget);
    });

    testWidgets('shows the four live metrics', (WidgetTester tester) async {
      await pumpAt(
        tester,
        dashboard(activeCount: 5, attentionCount: 2, runsToday: 3, slotsToday: 4, failureCount: 1),
      );
      expect(find.byKey(const Key('controlRoom.metric.active')), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.metric.attention')), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.metric.today')), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.metric.failures')), findsOneWidget);
      expect(find.text('5'), findsWidgets);
      expect(find.text('3/4'), findsOneWidget);
    });

    testWidgets('renders without overflow at every shipping width', (WidgetTester tester) async {
      for (final double width in <double>[320, 360, 414, 1024]) {
        await pumpAt(
          tester,
          dashboard(
            attentionCount: 2,
            findings: <GuardianFinding>[_finding()],
            today: _slots(),
            recent: _runs(),
            approvals: <ControlRoomApproval>[
              const ControlRoomApproval(id: 'a1', title: 'Send to Dad', isWhatsAppHandoff: false),
            ],
          ),
          width: width,
        );
        expect(tester.takeException(), isNull, reason: 'no overflow at $width dp');
      }
    });

    testWidgets('survives 1.8x accessibility text on a small phone',
        (WidgetTester tester) async {
      for (final double width in <double>[320, 360]) {
        await pumpAt(
          tester,
          dashboard(
            attentionCount: 1,
            findings: <GuardianFinding>[_finding()],
            today: _slots(),
            recent: _runs(),
          ),
          width: width,
          scale: 1.8,
        );
        expect(tester.takeException(), isNull, reason: '1.8x text at $width dp');
      }
    });

    testWidgets('shows the next automation and today’s timeline', (WidgetTester tester) async {
      await pumpAt(tester, dashboard(today: _slots(), recent: _runs()));
      expect(find.byKey(const Key('controlRoom.next')), findsOneWidget);
      expect(find.text('7:30 AM'), findsOneWidget);
      expect(find.text('Good morning Dad'), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.slot.wf1')), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.run.ex1')), findsOneWidget);
    });

    testWidgets('says so when there is nothing scheduled or no runs yet',
        (WidgetTester tester) async {
      await pumpAt(tester, dashboard(next: null));
      expect(find.byKey(const Key('controlRoom.today.empty')), findsOneWidget);
      expect(find.byKey(const Key('controlRoom.recent.empty')), findsOneWidget);
      expect(find.text('No scheduled automations'), findsOneWidget);
    });

    testWidgets('the bell opens the notification center and shows the unread count',
        (WidgetTester tester) async {
      int opens = 0;
      await pumpAt(tester, dashboard(unreadCount: 4, onOpenNotifications: () => opens++));
      expect(find.byKey(const Key('controlRoom.badge')), findsOneWidget);
      expect(find.text('4'), findsOneWidget);

      await tester.tap(find.byKey(const Key('controlRoom.bell')));
      await tester.pumpAndSettle();
      expect(opens, 1);
    });

    testWidgets('no badge when nothing is unread', (WidgetTester tester) async {
      await pumpAt(tester, dashboard(unreadCount: 0));
      expect(find.byKey(const Key('controlRoom.badge')), findsNothing);
    });

    testWidgets('guardian findings only appear when something is actually running',
        (WidgetTester tester) async {
      await pumpAt(tester, dashboard(activeCount: 0, findings: <GuardianFinding>[_finding()]));
      expect(find.text('Failed 3 times in a row'), findsNothing);

      await pumpAt(tester, dashboard(activeCount: 1, findings: <GuardianFinding>[_finding()]));
      expect(find.text('Failed 3 times in a row'), findsOneWidget);
    });

    testWidgets('says "not enough history" rather than implying all is well',
        (WidgetTester tester) async {
      await pumpAt(tester, dashboard(activeCount: 1, notEnoughHistory: true));
      expect(find.textContaining('Not enough history yet'), findsOneWidget);
    });
  });

  // ------------------------------------------------- notification center
  group('Notification Center', () {
    NotificationCenter centerWith(List<GuardianFinding> findings) =>
        const NotificationCenter().merge(findings, now: DateTime(2026, 3, 1, 8));

    Future<void> pumpInbox(
      WidgetTester tester,
      NotificationCenter center, {
      double width = 360,
      double scale = 1,
      NotificationFilter filter = NotificationFilter.all,
      ValueChanged<NotificationEntry>? onOpen,
      ValueChanged<NotificationEntry>? onDismiss,
      VoidCallback? onMarkAllRead,
    }) async =>
        pumpAt(
          tester,
          NotificationCenterView(
            center: center,
            filter: filter,
            onFilterChanged: (_) {},
            onOpen: onOpen ?? (_) {},
            onDismiss: onDismiss ?? (_) {},
            onMarkAllRead: onMarkAllRead ?? () {},
          ),
          width: width,
          scale: scale,
        );

    testWidgets('lists each finding with its subject and why', (WidgetTester tester) async {
      await pumpInbox(tester, centerWith(<GuardianFinding>[_finding(), _finding(workflowId: 'wf2')]));
      expect(find.byKey(const Key('nc.root')), findsOneWidget);
      expect(find.text('2 notifications · 2 unread'), findsOneWidget);
      expect(find.text('Morning text'), findsWidgets);
      expect(find.text('It will keep failing until it is fixed'), findsWidgets);
    });

    testWidgets('an empty inbox says why it is empty, never "all fine"',
        (WidgetTester tester) async {
      await pumpInbox(tester, centerWith(<GuardianFinding>[]));
      expect(find.byKey(const Key('nc.empty')), findsOneWidget);
      expect(find.text('Nothing needs your attention'), findsOneWidget);
    });

    testWidgets('the unread filter shows only unread rows', (WidgetTester tester) async {
      final NotificationCenter center =
          centerWith(<GuardianFinding>[_finding(), _finding(workflowId: 'wf2')])
              .markRead(_keyFor(_finding()));
      await pumpInbox(tester, center, filter: NotificationFilter.unread);
      expect(find.byKey(Key('nc.entry.${_keyFor(_finding())}')), findsNothing);
      expect(find.byKey(Key('nc.entry.${_keyFor(_finding(workflowId: 'wf2'))}')), findsOneWidget);
    });

    testWidgets('tapping a row opens what it points at', (WidgetTester tester) async {
      String? opened;
      await pumpInbox(
        tester,
        centerWith(<GuardianFinding>[_finding()]),
        onOpen: (NotificationEntry e) => opened = e.workflowId,
      );
      await tester.tap(find.byKey(Key('nc.action.${_keyFor(_finding())}')));
      await tester.pumpAndSettle();
      expect(opened, 'wf1');
    });

    testWidgets('dismissing a row reports which one', (WidgetTester tester) async {
      String? dismissed;
      await pumpInbox(
        tester,
        centerWith(<GuardianFinding>[_finding()]),
        onDismiss: (NotificationEntry e) => dismissed = e.key,
      );
      await tester.tap(find.byKey(Key('nc.dismiss.${_keyFor(_finding())}')));
      await tester.pumpAndSettle();
      expect(dismissed, _keyFor(_finding()));
    });

    testWidgets('mark all read is offered only when there is something unread',
        (WidgetTester tester) async {
      int marks = 0;
      await pumpInbox(
        tester,
        centerWith(<GuardianFinding>[_finding()]),
        onMarkAllRead: () => marks++,
      );
      await tester.tap(find.byKey(const Key('nc.markAllRead')));
      await tester.pumpAndSettle();
      expect(marks, 1);

      await pumpInbox(
        tester,
        centerWith(<GuardianFinding>[_finding()]).markAllRead(),
        onMarkAllRead: () => marks++,
      );
      expect(
        tester.widget<TextButton>(find.byKey(const Key('nc.markAllRead'))).onPressed,
        isNull,
        reason: 'nothing left to mark',
      );
    });

    testWidgets('renders without overflow at every shipping width and text scale',
        (WidgetTester tester) async {
      for (final double width in <double>[320, 360, 414, 1024]) {
        for (final double scale in <double>[1, 1.8]) {
          await pumpInbox(
            tester,
            centerWith(<GuardianFinding>[_finding(), _finding(workflowId: 'wf2')]),
            width: width,
            scale: scale,
          );
          expect(tester.takeException(), isNull, reason: 'no overflow at $width dp / ${scale}x');
        }
      }
    });

    testWidgets('a heuristic finding is never presented as fact', (WidgetTester tester) async {
      await pumpInbox(tester, centerWith(<GuardianFinding>[_finding(certain: false)]));
      expect(find.text('Looks unusual. This may be expected.'), findsOneWidget);
    });
  });
}

String _keyFor(GuardianFinding f) => NotificationCenter.keyFor(f);

GuardianFinding _finding({
  String workflowId = 'wf1',
  bool certain = true,
  bool isCloud = false,
  String? connectionId,
}) =>
    GuardianFinding(
      kind: 'repeated_failures',
      severity: FindingSeverity.critical,
      certain: certain,
      title: 'Failed 3 times in a row',
      body: 'Last error: boom',
      why: 'It will keep failing until it is fixed',
      isCloud: isCloud,
      automationName: 'Morning text',
      workflowId: workflowId,
      connectionId: connectionId,
      actionLabel: 'View automation',
      detectedAt: DateTime(2026, 3, 1, 8),
    );

List<ControlRoomSlot> _slots() => <ControlRoomSlot>[
      ControlRoomSlot(
        id: 'wf1',
        name: 'Morning text',
        time: '07:30',
        icon: Icons.check_circle,
        color: AutometaColors.success,
        statusLabel: 'SUCCESS',
      ),
    ];

List<ControlRoomRun> _runs() => <ControlRoomRun>[
      ControlRoomRun(
        id: 'ex1',
        name: 'Morning text',
        statusLabel: 'SUCCESS',
        color: AutometaColors.success,
        when: '5 minutes ago',
      ),
    ];
