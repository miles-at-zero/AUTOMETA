import 'package:flutter/foundation.dart';

import '../models/execution.dart';
import '../models/workflow.dart';
import 'automation_health.dart';

/// AUTOMETA GUARDIAN (foundation): things worth the user's attention, derived
/// only from real data. Cloud findings come from the server (`GET
/// /v1/guardian`, see server/src/cloud/guardian.js); on-device findings are
/// computed here from this phone's run records with the same health rules.
/// The two sources are never mixed: each finding knows its execution mode.
enum FindingSeverity { critical, attention, info }

@immutable
class GuardianFinding {
  const GuardianFinding({
    required this.kind,
    required this.severity,
    required this.certain,
    required this.title,
    required this.body,
    required this.isCloud,
    this.why = '',
    this.actionLabel,
    this.detectedAt,
    this.automationName,
    this.workflowId,
    this.cloudAutomationId,
    this.connectionId,
  });

  final String kind;
  final FindingSeverity severity;

  /// false = a heuristic ("looks unusual"); the UI must not present it as fact.
  final bool certain;
  final String title;
  final String body;
  final bool isCloud;

  /// Why Guardian cares (one sentence).
  final String why;

  /// Button label for the deep link ("View automation", "Reconnect"…).
  final String? actionLabel;
  final DateTime? detectedAt;
  final String? automationName;

  /// Local workflow id (on-device findings).
  final String? workflowId;

  /// Server automation id (Cloud findings); map to a local workflow via
  /// [Workflow.cloudId].
  final String? cloudAutomationId;
  final String? connectionId;

  static FindingSeverity _sev(Object? s) => switch ('$s') {
        'critical' => FindingSeverity.critical,
        'attention' => FindingSeverity.attention,
        _ => FindingSeverity.info,
      };

  /// Parses the server report. Unknown/malformed rows are dropped, not guessed.
  static List<GuardianFinding> fromCloudReport(Map<String, dynamic> report) {
    final Object? raw = report['findings'];
    if (raw is! List) return const <GuardianFinding>[];
    final List<GuardianFinding> out = <GuardianFinding>[];
    for (final Object? f in raw) {
      if (f is! Map) continue;
      final String title = '${f['title'] ?? ''}';
      if (title.isEmpty) continue;
      out.add(GuardianFinding(
        kind: '${f['kind'] ?? ''}',
        severity: _sev(f['severity']),
        certain: f['certainty'] == 'certain',
        title: title,
        body: '${f['body'] ?? ''}',
        why: '${f['why'] ?? ''}',
        actionLabel: f['action'] is Map ? (f['action'] as Map)['label'] as String? : null,
        detectedAt: f['detectedAt'] is num ? DateTime.fromMillisecondsSinceEpoch((f['detectedAt'] as num).toInt()) : null,
        isCloud: true,
        automationName: f['automationName'] as String?,
        cloudAutomationId: f['automationId'] as String?,
        connectionId: f['connectionId'] as String?,
      ));
    }
    return out;
  }

  /// On-device automations only (Cloud ones are judged by the server).
  static List<GuardianFinding> forDevice(Iterable<Workflow> workflows, Iterable<ExecutionRecord> records, DateTime now) {
    final List<GuardianFinding> out = <GuardianFinding>[];
    for (final Workflow w in workflows) {
      if (w.isCloud || !w.enabled) continue;
      final AutomationHealth h = AutomationHealth.evaluate(
        enabled: true,
        runs: records.where((ExecutionRecord r) => r.workflowId == w.id).map(RunSample.fromRecord).whereType<RunSample>(),
        now: now,
      );
      if (h.state != HealthState.critical && h.state != HealthState.attention) continue;
      out.add(GuardianFinding(
        kind: h.state == HealthState.critical ? 'repeated_failures' : 'recent_failures',
        severity: h.state == HealthState.critical ? FindingSeverity.critical : FindingSeverity.attention,
        certain: true,
        title: h.state == HealthState.critical
            ? 'Failed ${h.reasons.first.replaceAll(RegExp(r'[^0-9]'), '')} times in a row'
            : h.reasons.first,
        why: h.state == HealthState.critical
            ? 'Repeated failures usually mean something changed, and it will keep failing until it is fixed.'
            : 'A recent failure means at least one run did not do its job.',
        body: h.lastFailureReason == null ? 'Open the latest run to see what went wrong.' : 'Last error: ${h.lastFailureReason}',
        actionLabel: 'View automation',
        detectedAt: now,
        isCloud: false,
        automationName: w.name,
        workflowId: w.id,
      ));
    }
    return out;
  }

  /// True when at least one active on-device automation has a finished,
  /// non-skipped run to judge (health is not "not enough history").
  static bool deviceHasHistory(Iterable<Workflow> workflows, Iterable<ExecutionRecord> records, DateTime now) {
    for (final Workflow w in workflows) {
      if (w.isCloud || !w.enabled) continue;
      final AutomationHealth h = AutomationHealth.evaluate(
        enabled: true,
        runs: records.where((ExecutionRecord r) => r.workflowId == w.id).map(RunSample.fromRecord).whereType<RunSample>(),
        now: now,
      );
      if (h.state != HealthState.unknown) return true;
    }
    return false;
  }

  /// True when the server judged at least one Cloud automation from real runs
  /// (`summary.healthy + attention + critical > 0`).
  static bool cloudHasHistory(Map<String, dynamic> report) {
    final Object? s = report['summary'];
    if (s is! Map) return false;
    int n(String k) => s[k] is num ? (s[k] as num).toInt() : 0;
    return n('healthy') + n('attention') + n('critical') > 0;
  }

  /// Same order as the server: critical failures, connections, missed
  /// schedules, other failures, inactivity. Stable for equal ranks.
  static const Map<String, int> _rank = <String, int>{
    'paused_after_failures': 0, 'repeated_failures': 0, 'connection_attention': 1,
    'missed_schedule': 2, 'schedule_overdue': 2, 'recent_failures': 3, 'looks_inactive': 4,
  };

  int get rank => _rank[kind] ?? 9;

  static List<GuardianFinding> sorted(Iterable<GuardianFinding> all) {
    final List<GuardianFinding> list = all.toList();
    final List<int> idx = List<int>.generate(list.length, (int i) => i);
    idx.sort((int a, int b) {
      final int c = list[a].rank.compareTo(list[b].rank);
      return c != 0 ? c : a.compareTo(b);
    });
    return <GuardianFinding>[for (final int i in idx) list[i]];
  }
}
