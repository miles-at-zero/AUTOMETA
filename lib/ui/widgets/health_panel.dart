import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/health/automation_health.dart';
import 'autometa_widgets.dart';

Color healthColor(HealthState s) => switch (s) {
      HealthState.healthy => AutometaColors.success,
      HealthState.attention => AutometaColors.warning,
      HealthState.critical => AutometaColors.danger,
      HealthState.inactive || HealthState.unknown => AutometaColors.neutral,
    };

/// AUTOMATION HEALTH card: state, the reasons behind it, and the real counts
/// it was derived from. [health] null = history couldn't be read (shown as
/// such, never guessed).
class HealthPanel extends StatelessWidget {
  const HealthPanel({required this.health, required this.isCloud, super.key});

  final AutomationHealth? health;
  final bool isCloud;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final AutomationHealth? h = health;
    if (h == null) {
      return Panel(
        key: const Key('health.unavailable'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('HEALTH', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
          const SizedBox(height: AutometaSpacing.xs),
          Text(isCloud
              ? 'Cloud history isn\'t available right now (signed out or offline), so health can\'t be checked.'
              : 'History isn\'t available right now, so health can\'t be checked.'),
        ]),
      );
    }
    final Color c = healthColor(h.state);
    return Panel(
      key: Key('health.${h.state.name}'),
      borderColor: c.withValues(alpha: 0.45),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text('HEALTH', style: t.labelLarge?.copyWith(letterSpacing: 1.2))),
          Flexible(child: StatusPill(label: '${h.state.emoji} ${h.state.label.toUpperCase()}', color: c, filled: true)),
        ]),
        const SizedBox(height: AutometaSpacing.sm),
        for (final String r in h.reasons)
          Padding(
            padding: const EdgeInsets.only(bottom: AutometaSpacing.xs),
            child: Text(r, style: t.bodyMedium),
          ),
        if (h.sampleSize > 0) ...<Widget>[
          const SizedBox(height: AutometaSpacing.sm),
          Text('HISTORY · last ${h.sampleSize} ${h.sampleSize == 1 ? 'run' : 'runs'} ${isCloud ? 'on Cloud' : 'on this device'}',
              style: t.labelSmall?.copyWith(letterSpacing: 1.1)),
          const SizedBox(height: AutometaSpacing.xs),
          Wrap(spacing: AutometaSpacing.lg, runSpacing: AutometaSpacing.xs, children: <Widget>[
            _Count('Succeeded', h.succeeded, AutometaColors.success),
            _Count('Failed', h.failed, AutometaColors.danger),
            _Count('Skipped', h.skipped, AutometaColors.neutral),
          ]),
          const SizedBox(height: AutometaSpacing.sm),
          if (h.lastRun != null) LabeledValue(label: 'Last run', value: Formatters.stamp(h.lastRun!.toLocal())),
          if (h.lastFailure != null) LabeledValue(label: 'Last failure', value: Formatters.stamp(h.lastFailure!.toLocal())),
          if (h.mostCommonFailure != null) LabeledValue(label: 'Most common failure', value: h.mostCommonFailure!),
        ],
      ]),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: <Widget>[
      Text('$value', style: t.titleLarge?.copyWith(color: value == 0 ? null : color, fontWeight: FontWeight.w700)),
      Text(label, style: t.bodySmall),
    ]);
  }
}
