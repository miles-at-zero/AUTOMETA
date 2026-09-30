import 'package:flutter/material.dart';

import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/models/execution.dart';
import '../../domain/validation/workflow_validator.dart';
import '../widgets/autometa_widgets.dart';

/// "DRY RUN — No real action will be performed." (spec §24).
Future<void> showDryRunSheet(BuildContext context, DryRunReport report) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(AutometaSpacing.xl, 0, AutometaSpacing.xl, AutometaSpacing.xl),
            children: <Widget>[
              const StatusPill(label: 'DRY RUN · SIMULATION', color: AutometaColors.warning, filled: true),
              const SizedBox(height: AutometaSpacing.md),
              Text(report.workflow.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: AutometaSpacing.sm),
              LabeledValue(
                label: 'Trigger',
                value: report.wouldRunAt == null
                    ? report.workflow.trigger.describe()
                    : '${report.workflow.trigger.describe()}\nNext: ${Formatters.stamp(report.wouldRunAt!.toLocal())}',
              ),
              const SizedBox(height: AutometaSpacing.md),
              const SectionLabel('Would execute'),
              for (final StepExecution s in report.record.stepResults)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(stepIcon(s.kind)),
                  title: Text(s.title),
                  subtitle: s.detail == null ? null : Text(s.detail!),
                ),
              if (report.record.failureReason != null)
                Text(report.record.failureReason!, style: const TextStyle(color: AutometaColors.danger)),
              for (final ValidationIssue i in report.validation.issues)
                Text('• ${i.message}', style: TextStyle(color: i.isError ? AutometaColors.danger : AutometaColors.warning)),
              const SizedBox(height: AutometaSpacing.lg),
              Text('No real action was performed.', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
