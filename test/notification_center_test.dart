// Guardian Notification Center: de-duplication, read / dismissed state and
// persistence.
//
// The behaviour under test is the thing the product explicitly needed: Guardian
// re-derives its findings on every pass, so without a stable identity the same
// failing automation would drop a fresh "unread" row into the inbox on every
// refresh and nag the user forever.
import 'package:autometa/domain/health/guardian.dart';
import 'package:autometa/domain/notifications/notification_center.dart';
import 'package:autometa/domain/notifications/notification_store.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime t0 = DateTime(2026, 3, 1, 8);
final DateTime t1 = DateTime(2026, 3, 1, 9);
final DateTime t2 = DateTime(2026, 3, 1, 10);

GuardianFinding finding({
  String kind = 'repeated_failures',
  FindingSeverity severity = FindingSeverity.critical,
  bool certain = true,
  String title = 'Failed 3 times in a row',
  String body = 'Last error: boom',
  String why = 'It will keep failing until it is fixed',
  bool isCloud = false,
  String? automationName = 'Morning text',
  String? workflowId = 'wf1',
  String? cloudAutomationId,
  String? connectionId,
  DateTime? detectedAt,
  String actionLabel = 'View automation',
}) =>
    GuardianFinding(
      kind: kind,
      severity: severity,
      certain: certain,
      title: title,
      body: body,
      why: why,
      isCloud: isCloud,
      automationName: automationName,
      workflowId: workflowId,
      cloudAutomationId: cloudAutomationId,
      connectionId: connectionId,
      detectedAt: detectedAt,
      actionLabel: actionLabel,
    );

void main() {
  // ------------------------------------------------------------ identity
  group('stable identity', () {
    test('the same problem on the same automation is one notification', () {
      const NotificationCenter center = NotificationCenter();
      final NotificationCenter first = center.merge(<GuardianFinding>[finding()], now: t0);
      final NotificationCenter second = first.merge(<GuardianFinding>[finding()], now: t1);

      expect(first.entries.length, 1);
      expect(second.entries.length, 1,
          reason: 'a refresh must not add a second copy of the same problem');
      expect(second.entries.single.key, first.entries.single.key);
    });

    test('first-seen time survives a refresh, so "2h ago" does not reset', () {
      final NotificationCenter center =
          const NotificationCenter().merge(<GuardianFinding>[finding(detectedAt: t0)], now: t0);
      final NotificationCenter again =
          center.merge(<GuardianFinding>[finding(detectedAt: t1)], now: t1);

      expect(again.entries.single.firstSeenAt, t0,
          reason: 'the inbox reports when Guardian first noticed, not the last refresh');
    });

    test('different problems, automations and modes are different notifications', () {
      final NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[
          finding(kind: 'repeated_failures', workflowId: 'wf1'),
          finding(kind: 'missed_schedule', workflowId: 'wf1'),
          finding(kind: 'repeated_failures', workflowId: 'wf2'),
          finding(kind: 'repeated_failures', workflowId: 'wf3', isCloud: true, cloudAutomationId: 'c3'),
        ],
        now: t0,
      );
      expect(center.entries.length, 4);
    });

    test('a finding with no subject still gets a stable, distinct key', () {
      final NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[
          finding(kind: 'connection_attention', workflowId: null, connectionId: 'gmail'),
          finding(kind: 'connection_attention', workflowId: null, connectionId: 'telegram'),
        ],
        now: t0,
      );
      expect(center.entries.length, 2);
      expect(center.entries.first.category, NotificationCategory.connection);
    });
  });

  // ------------------------------------------------------------ de-dup / nag
  group('does not nag', () {
    test('a finding the user already read stays read across refreshes', () {
      NotificationCenter center =
          const NotificationCenter().merge(<GuardianFinding>[finding()], now: t0);
      expect(center.unreadCount, 1);

      center = center.markAllRead();
      expect(center.unreadCount, 0);

      center = center.merge(<GuardianFinding>[finding()], now: t1);
      expect(center.entries.single.isRead, isTrue,
          reason: 'Guardian re-reporting the same thing is not news');
      expect(center.unreadCount, 0);
    });

    test('changed wording comes back as unread: that is new information', () {
      NotificationCenter center =
          const NotificationCenter().merge(<GuardianFinding>[finding(body: 'Last error: boom')], now: t0);
      center = center.markAllRead();
      expect(center.unreadCount, 0);

      center = center.merge(<GuardianFinding>[finding(body: 'Last error: connection refused')], now: t1);
      expect(center.entries.single.isRead, isFalse);
      expect(center.unreadCount, 1);
    });

    test('a resolved problem leaves the inbox', () {
      NotificationCenter center = const NotificationCenter()
          .merge(<GuardianFinding>[finding(workflowId: 'wf1'), finding(workflowId: 'wf2')], now: t0);
      expect(center.entries.length, 2);

      center = center.merge(<GuardianFinding>[finding(workflowId: 'wf2')], now: t1);
      expect(center.entries.length, 1);
      expect(center.entries.single.workflowId, 'wf2');
    });
  });

  // ------------------------------------------------------------ dismissal
  group('dismissal', () {
    test('a dismissed row is hidden while Guardian keeps reporting the same wording', () {
      NotificationCenter center =
          const NotificationCenter().merge(<GuardianFinding>[finding()], now: t0);
      final String key = center.entries.single.key;

      center = center.dismiss(key);
      expect(center.isEmpty, isTrue);

      center = center.merge(<GuardianFinding>[finding()], now: t1);
      expect(center.isEmpty, isTrue, reason: 'dismissing must stick, not bounce straight back');
    });

    test('a dismissed row returns when Guardian reports something different', () {
      NotificationCenter center =
          const NotificationCenter().merge(<GuardianFinding>[finding(body: 'A')], now: t0);
      final String key = center.entries.single.key;

      center = center.dismiss(key).merge(<GuardianFinding>[finding(body: 'A')], now: t1);
      expect(center.isEmpty, isTrue);

      center = center.merge(<GuardianFinding>[finding(body: 'B')], now: t2);
      expect(center.entries.length, 1, reason: 'new information should not stay hidden');
      expect(center.entries.single.isRead, isFalse);
    });
  });

  // ------------------------------------------------------------ ordering
  group('ordering and counts', () {
    test('critical first, then newest first', () {
      final NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[
          finding(kind: 'looks_inactive', severity: FindingSeverity.info, workflowId: 'a', detectedAt: t2),
          finding(kind: 'repeated_failures', severity: FindingSeverity.critical, workflowId: 'b', detectedAt: t0),
          finding(kind: 'recent_failures', severity: FindingSeverity.attention, workflowId: 'c', detectedAt: t1),
          finding(kind: 'repeated_failures', severity: FindingSeverity.critical, workflowId: 'd', detectedAt: t1),
        ],
        now: t2,
      );
      expect(
        center.entries.map((NotificationEntry e) => e.workflowId).toList(),
        <String>['d', 'b', 'c', 'a'],
      );
    });

    test('counts and filtering', () {
      NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[
          finding(workflowId: 'a'),
          finding(workflowId: 'b', severity: FindingSeverity.attention),
          finding(workflowId: 'c'),
        ],
        now: t0,
      );
      expect(center.unreadCount, 3);
      expect(center.criticalCount, 2);
      expect(center.countFor(NotificationFilter.all), 3);
      expect(center.countFor(NotificationFilter.unread), 3);

      center = center.markRead(center.entries.first.key);
      expect(center.unreadCount, 2);
      expect(center.countFor(NotificationFilter.all), 3);
      expect(center.countFor(NotificationFilter.unread), 2);
      expect(center.visible(NotificationFilter.unread).length, 2);
    });

    test('mark all read leaves the entries in place', () {
      final NotificationCenter center = const NotificationCenter()
          .merge(<GuardianFinding>[finding(workflowId: 'a'), finding(workflowId: 'b')], now: t0)
          .markAllRead();
      expect(center.entries.length, 2);
      expect(center.unreadCount, 0);
    });
  });

  // ------------------------------------------------------------ persistence
  group('persistence', () {
    test('read and dismissed state round-trips through the store', () {
      NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[finding(workflowId: 'a'), finding(workflowId: 'b')],
        now: t0,
      );
      center = center.markRead(center.entries.first.key);
      center = center.dismiss(center.entries.last.key);

      final NotificationCenter restored = NotificationStore.restore(
        read: NotificationStore.encodeRead(center),
        dismissed: NotificationStore.encodeDismissed(center),
      );

      // A cold start has no entries yet; the persisted state must survive the
      // first merge rather than being wiped.
      final NotificationCenter merged =
          restored.merge(<GuardianFinding>[finding(workflowId: 'a'), finding(workflowId: 'b')], now: t1);
      expect(merged.entries.length, 1, reason: 'the dismissed one stays hidden');
      expect(merged.entries.single.workflowId, 'a');
      expect(merged.entries.single.isRead, isTrue);
      expect(merged.unreadCount, 0);
    });

    test('hostile names and error text cannot corrupt the encoding', () {
      final NotificationCenter center = const NotificationCenter().merge(
        <GuardianFinding>[
          finding(
            workflowId: 'wf\n1',
            automationName: 'Morning\x1Dtext',
            title: 'Bad\x1Ename',
            body: 'Error:\x1Foops',
          ),
        ],
        now: t0,
      ).markAllRead();

      final String read = NotificationStore.encodeRead(center);
      final String dismissed =
          NotificationStore.encodeDismissed(center.dismiss(center.entries.single.key));

      final NotificationCenter restored =
          NotificationStore.restore(read: read, dismissed: dismissed);
      expect(restored.readKeys.length, 1);
      expect(restored.dismissed.length, 1);

      // Round-trip a second time: still one record, not a split one.
      final NotificationCenter second = const NotificationCenter()
          .merge(<GuardianFinding>[finding(workflowId: 'wf\n1', body: 'Error:\x1Foops')], now: t1);
      expect(second.entries.length, 1);
      expect(NotificationStore.decodeDismissed(NotificationStore.encodeDismissed(restored)).length, 1);
    });

    test('an empty store decodes to empty state', () {
      final NotificationCenter restored = NotificationStore.restore(read: '', dismissed: null);
      expect(restored.readKeys, isEmpty);
      expect(restored.dismissed, isEmpty);
      expect(restored.entries, isEmpty);
    });
  });
}
