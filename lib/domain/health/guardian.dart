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
        title: h.reasons.first,
        body: h.lastFailureReason ?? 'Open the latest run to see what went wrong.',
        isCloud: false,
        automationName: w.name,
        workflowId: w.id,
      ));
    }
    return out;
  }

  static List<GuardianFinding> sorted(Iterable<GuardianFinding> all) =>
      all.toList()..sort((GuardianFinding a, GuardianFinding b) => a.severity.index.compareTo(b.severity.index));
}
