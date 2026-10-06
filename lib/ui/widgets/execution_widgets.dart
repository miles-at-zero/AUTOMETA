import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import '../../domain/capabilities/execution_capabilities.dart';
import '../../domain/models/execution_mode.dart';
import '../../domain/models/workflow.dart';
import 'autometa_widgets.dart';

enum ExecutionBadgeState { normal, recommended, unavailable, needsAttention }

/// Reusable execution-mode badge: "☁️ Cloud", "📱 On-device",
/// "Cloud • Recommended", "Unavailable", "Needs attention".
class AutometaExecutionBadge extends StatelessWidget {
  const AutometaExecutionBadge({required this.mode, this.state = ExecutionBadgeState.normal, this.compact = false, super.key});

  final ExecutionMode mode;
  final ExecutionBadgeState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (String label, Color color, IconData icon) = switch (state) {
      ExecutionBadgeState.unavailable => ('Unavailable', AutometaColors.neutral, Icons.block),
      ExecutionBadgeState.needsAttention => ('Needs attention', AutometaColors.warning, Icons.error_outline),
      ExecutionBadgeState.recommended => ('Cloud • Recommended', AutometaColors.accent, Icons.cloud_outlined),
      ExecutionBadgeState.normal => mode.isCloud
          ? ('Cloud', AutometaColors.accent, Icons.cloud_outlined)
          : (compact ? 'On-device' : 'On this device', AutometaColors.secondary, Icons.smartphone),
    };
    return Semantics(
      label: 'Execution: $label',
      child: StatusPill(label: label, color: color, icon: icon, filled: true),
    );
  }
}

/// Makes the builder's execution mode visible to nested block pickers.
class ExecutionModeScope extends InheritedWidget {
  const ExecutionModeScope({required this.mode, required super.child, super.key});

  final ExecutionMode mode;

  static ExecutionMode? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ExecutionModeScope>()?.mode;

  @override
  bool updateShouldNotify(ExecutionModeScope oldWidget) => oldWidget.mode != mode;
}

/// The "Execution" section: Cloud (recommended, default) vs On this device.
/// Cloud is visually primary; On-device shows the OS caveat when chosen.
class ExecutionSelector extends StatelessWidget {
  const ExecutionSelector({required this.workflow, required this.onChanged, super.key});

  final Workflow workflow;
  final ValueChanged<ExecutionMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final List<CapabilityIssue> cloudIssues = ExecutionCapabilities.check(workflow, ExecutionMode.cloud);
    final List<CapabilityIssue> deviceIssues = ExecutionCapabilities.check(workflow, ExecutionMode.onDevice);
    final bool wide = MediaQuery.sizeOf(context).width >= 640;
    final List<Widget> options = <Widget>[
      _Option(
        selected: workflow.isCloud,
        recommended: true,
        icon: Icons.cloud_outlined,
        title: 'Cloud',
        tagline: ExecutionCopy.cloudTagline,
        bestFor: const <String>['Scheduled automations', 'Cross-app workflows', 'Reliable background runs', 'Available on all your devices'],
        issues: cloudIssues,
        onTap: () => onChanged(ExecutionMode.cloud),
      ),
      _Option(
        selected: !workflow.isCloud,
        icon: Icons.smartphone,
        title: 'On this device',
        tagline: ExecutionCopy.deviceTagline,
        bestFor: const <String>['Simple device-specific automations', 'Local actions (WhatsApp prepare, clipboard, links)', 'No account needed'],
        mayNeed: 'May need notification, exact-alarm and battery permissions.',
        issues: deviceIssues,
        onTap: () => onChanged(ExecutionMode.onDevice),
      ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      Text('EXECUTION', style: Theme.of(context).textTheme.labelLarge?.copyWith(letterSpacing: 1.2)),
      const SizedBox(height: AutometaSpacing.sm),
      if (wide)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Expanded(child: options[0]),
            const SizedBox(width: AutometaSpacing.md),
            Expanded(child: options[1]),
          ]),
        )
      else ...<Widget>[options[0], const SizedBox(height: AutometaSpacing.sm), options[1]],
      if (!workflow.isCloud) ...<Widget>[
        const SizedBox(height: AutometaSpacing.sm),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const Icon(Icons.info_outline, size: 16, color: AutometaColors.warning),
          const SizedBox(width: 6),
          Expanded(child: Text(ExecutionCopy.recommendation, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      ],
    ]);
  }
}

class _Option extends StatelessWidget {
  const _Option({
    required this.selected,
    required this.icon,
    required this.title,
    required this.tagline,
    required this.bestFor,
    required this.issues,
    required this.onTap,
    this.recommended = false,
    this.mayNeed,
  });

  final bool selected;
  final bool recommended;
  final IconData icon;
  final String title;
  final String tagline;
  final List<String> bestFor;
  final String? mayNeed;
  final List<CapabilityIssue> issues;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tone = recommended ? AutometaColors.accent : AutometaColors.secondary;
    final TextTheme t = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '$title${recommended ? ', recommended' : ''}',
      child: Panel(
        onTap: onTap,
        glow: selected ? tone : null,
        borderColor: selected ? tone : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? tone : null, size: 20),
            const SizedBox(width: 8),
            Icon(icon, color: tone, size: 20),
            const SizedBox(width: 6),
            Expanded(child: Text(title, style: t.titleMedium)),
            if (recommended) const StatusPill(label: 'Recommended', color: AutometaColors.accent, filled: true),
          ]),
          const SizedBox(height: 6),
          Text(tagline, style: t.bodyMedium),
          const SizedBox(height: 6),
          for (final String b in bestFor) Text('• $b', style: t.bodySmall),
          if (mayNeed != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(mayNeed!, style: t.bodySmall)),
          if (issues.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text('${issues.length} block${issues.length == 1 ? '' : 's'} can\'t run here:',
                style: t.labelMedium?.copyWith(color: AutometaColors.warning)),
            for (final CapabilityIssue i in issues.take(3))
              Text('• ${i.label}', style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
    );
  }
}

/// "Cannot move" sheet listing the incompatible steps (spec §11).
Future<String?> showMoveBlockedSheet(BuildContext context, {required String title, required String message, required List<CapabilityIssue> issues, required String keepLabel}) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Text(title, style: Theme.of(c).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message),
            const SizedBox(height: 12),
            for (final CapabilityIssue i in issues)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  const Icon(Icons.error_outline, size: 18, color: AutometaColors.warning),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${i.label}: ${i.reason}')),
                ]),
              ),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(c, 'edit'), child: const Text('Edit automation')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => Navigator.pop(c, 'keep'), child: Text(keepLabel)),
          ]),
        ),
      ),
    );
