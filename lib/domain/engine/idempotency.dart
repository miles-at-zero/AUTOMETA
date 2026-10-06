import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/step.dart';
import '../models/workflow.dart';

/// Duplicate-execution protection (spec §21).
///
/// The key is deterministic and derived from the *scheduled* moment rather
/// than the moment the alarm happened to fire, so a late alarm, a device
/// reboot replay and a manual re-arm all collapse onto the same key.
class IdempotencyKeys {
  const IdempotencyKeys._();

  /// `workflow + date + scheduled_time + target`.
  static String forScheduledRun({
    required Workflow workflow,
    required DateTime scheduledFor,
    String? overrideTarget,
  }) {
    final DateTime moment = scheduledFor.toUtc();
    final String date = '${moment.year.toString().padLeft(4, '0')}-'
        '${moment.month.toString().padLeft(2, '0')}-'
        '${moment.day.toString().padLeft(2, '0')}';
    final String time = '${moment.hour.toString().padLeft(2, '0')}:'
        '${moment.minute.toString().padLeft(2, '0')}';
    final String target = overrideTarget ?? primaryTargetOf(workflow);
    return build(workflowId: workflow.id, date: date, time: time, target: target);
  }

  /// Test runs and manual runs must never collide with a scheduled run, and
  /// must never collide with each other either.
  static String forAdHocRun({
    required Workflow workflow,
    required DateTime startedAt,
    required String kind,
  }) =>
      build(
        workflowId: workflow.id,
        date: kind,
        time: '${startedAt.toUtc().microsecondsSinceEpoch}',
        target: 'adhoc',
      );

  static String build({
    required String workflowId,
    required String date,
    required String time,
    required String target,
  }) {
    final String raw = '$workflowId|$date|$time|$target';
    return '$workflowId-${fnv1a(raw)}';
  }

  /// The "target" half of the key: who or what the run is aimed at.
  ///
  /// Two workflows that message the same person at the same minute still get
  /// different keys because the workflow id is part of the key; a workflow
  /// whose recipient changes between arms gets a new key, which is the desired
  /// behaviour because it is genuinely a different delivery.
  static String primaryTargetOf(Workflow workflow) {
    for (final WorkflowStep step in _flatten(workflow.steps)) {
      if (step is WhatsAppStep) return 'wa:${step.recipient}';
      if (step is HttpStep) return 'http:${step.url}';
      if (step is WebhookStep) return 'hook:${step.url}';
    }
    return 'wf:${workflow.id}';
  }

  static Iterable<WorkflowStep> _flatten(List<WorkflowStep> steps) sync* {
    for (final WorkflowStep step in steps) {
      yield step;
      if (step is ConditionStep) {
        yield* _flatten(step.thenSteps);
        yield* _flatten(step.elseSteps);
      }
    }
  }

  /// 64-bit FNV-1a over the UTF-8 bytes, rendered as zero-padded hex.
  ///
  /// Implemented locally so the engine has no dependency on a crypto package;
  /// this is a collision-avoidance key, not a security primitive.
  static String fnv1a(String input) {
    const int offset = 0xcbf29ce484222325;
    const int prime = 0x100000001b3;
    int hash = offset;
    for (final int byte in utf8.encode(input)) {
      hash = (hash ^ byte) & 0xFFFFFFFFFFFFFFFF;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}

/// In-memory guard used within a single process lifetime.
///
/// The durable guard is the unique index on `executions.idempotency_key`;
/// this class short-circuits before a row is even written.
class InMemoryIdempotencyGuard {
  final Map<String, DateTime> _seen = <String, DateTime>{};

  /// Returns true when [key] has not been seen before, and records it.
  bool claim(String key, {DateTime? at}) {
    final DateTime now = at ?? DateTime.now();
    _seen.removeWhere((String k, DateTime v) => now.difference(v).inHours > 48);
    if (_seen.containsKey(key)) return false;
    _seen[key] = now;
    return true;
  }

  bool contains(String key) => _seen.containsKey(key);

  void forget(String key) => _seen.remove(key);

  void clear() => _seen.clear();

  int get size => _seen.length;
}
