import 'package:autometa/domain/health/guardian.dart';
import 'package:autometa/domain/models/execution.dart';
import 'package:autometa/domain/models/execution_mode.dart';
import 'package:autometa/domain/models/execution_status.dart';
import 'package:autometa/domain/models/step.dart';
import 'package:autometa/domain/models/trigger.dart';
import 'package:autometa/domain/models/workflow.dart';
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
      expect(fs.single.body, 'No internet');
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
}
