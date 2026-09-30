/// Lifecycle states of a workflow execution (spec §20).
enum ExecutionStatus {
  /// Created but not yet started (e.g. queued behind a retry backoff).
  pending('PENDING', 'Pending'),

  /// The engine is running the steps right now.
  running('RUNNING', 'Running'),

  /// Every step finished and every real side effect completed.
  success('SUCCESS', 'Completed'),

  /// A step failed and retries were exhausted.
  failed('FAILED', 'Failed'),

  /// The user (or the engine) stopped the run before it completed.
  cancelled('CANCELLED', 'Cancelled'),

  /// Nothing was done on purpose: duplicate schedule, paused engine,
  /// condition not met, or the integration is unavailable.
  skipped('SKIPPED', 'Skipped'),

  /// Blocked on an explicit user approval (spec §23).
  waitingApproval('WAITING_APPROVAL', 'Waiting for approval');

  const ExecutionStatus(this.wire, this.label);

  /// Value persisted in SQLite / exchanged in JSON.
  final String wire;

  /// Label shown in the UI.
  final String label;

  bool get isTerminal =>
      this == success || this == failed || this == cancelled || this == skipped;

  bool get needsAttention => this == failed || this == waitingApproval;

  static ExecutionStatus fromWire(Object? value) {
    final String raw = '$value'.toUpperCase();
    for (final ExecutionStatus status in ExecutionStatus.values) {
      if (status.wire == raw || status.name.toUpperCase() == raw) return status;
    }
    return ExecutionStatus.pending;
  }
}
