/// Where an automation runs. A property of the automation, not a separate
/// system: both modes share the same Workflow / trigger / step / condition
/// models and validator, and differ only in the execution adapter.
enum ExecutionMode {
  /// Runs on the Autometa backend scheduler + workers. Recommended default.
  cloud('cloud', 'Cloud', '☁️'),

  /// Runs on this phone through Android alarms and the local engine.
  onDevice('on_device', 'On this device', '📱');

  const ExecutionMode(this.wire, this.label, this.emoji);

  final String wire;
  final String label;
  final String emoji;

  bool get isCloud => this == ExecutionMode.cloud;

  static const ExecutionMode recommended = ExecutionMode.cloud;

  static ExecutionMode fromWire(Object? value, {ExecutionMode fallback = ExecutionMode.onDevice}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final ExecutionMode m in ExecutionMode.values) {
      if (m.wire == raw || m.name.toLowerCase() == raw) return m;
    }
    return fallback;
  }
}

/// Shared wording so the UI never drifts.
abstract final class ExecutionCopy {
  static const String recommendation =
      'Cloud is recommended for reliable automation. On-device automations may pause or be affected by operating-system restrictions.';
  static const String cloudTagline = 'Runs even when Autometa is closed or your phone is offline.';
  static const String deviceTagline = 'Runs locally on this device, when Android allows it.';
}
