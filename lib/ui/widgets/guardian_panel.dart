import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../domain/health/guardian.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/workflow.dart';
import '../../state/app_state.dart';
import '../screens/cloud_account_screen.dart';
import '../screens/workflow_history_screen.dart';
import 'autometa_widgets.dart';

Color findingColor(FindingSeverity s) => switch (s) {
      FindingSeverity.critical => AutometaColors.danger,
      FindingSeverity.attention => AutometaColors.warning,
      FindingSeverity.info => AutometaColors.info,
    };

/// Result of one Guardian check. [cloudChecked] false = Cloud findings could
/// not be loaded (signed out / offline), which the panel says instead of
/// implying everything is fine.
class _Report {
  const _Report(this.findings, {required this.cloudChecked, required this.cloudRelevant});
  final List<GuardianFinding> findings;
  final bool cloudChecked;
  final bool cloudRelevant;
}

/// GUARDIAN on Home: "N things need your attention", from real data only.
/// Hidden entirely when there are no active automations to watch.
class GuardianPanel extends StatefulWidget {
  const GuardianPanel({super.key});

  @override
  State<GuardianPanel> createState() => _GuardianPanelState();
}

class _GuardianPanelState extends State<GuardianPanel> {
  Future<_Report>? _report;

  @override
  void initState() {
    super.initState();
    _report = _load();
  }

  Future<_Report> _load() async {
    final AppState state = context.read<AppState>();
    final AppServices services = context.read<AppServices>();
    final CloudSession cloud = context.read<CloudSession>();
    final List<Workflow> workflows = List<Workflow>.of(state.workflows);
    final List<ExecutionRecord> local = await services.executions.recent(limit: 300);
    final List<GuardianFinding> found = GuardianFinding.forDevice(workflows, local, DateTime.now());
    final bool cloudRelevant = workflows.any((Workflow w) => w.isCloud && w.enabled);
    bool cloudChecked = false;
    if (cloud.signedIn) {
      try {
        found.addAll(GuardianFinding.fromCloudReport(await cloud.guardian()));
        cloudChecked = true;
      } catch (_) {
        cloudChecked = false;
      }
    }
    return _Report(GuardianFinding.sorted(found), cloudChecked: cloudChecked, cloudRelevant: cloudRelevant);
  }

  void _open(GuardianFinding f) {
    final List<Workflow> ws = context.read<AppState>().workflows;
    Widget? target;
    if (f.connectionId != null) {
      target = CloudAccountScreen(reconnectConnectionId: f.connectionId);
    } else {
      final Workflow? w = ws.cast<Workflow?>().firstWhere(
            (Workflow? w) => w != null && (w.id == f.workflowId || (f.cloudAutomationId != null && w.cloudId == f.cloudAutomationId)),
            orElse: () => null,
          );
      if (w != null) target = AutomationDetailScreen(workflow: w);
    }
    if (target != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target!));
  }

  @override
  Widget build(BuildContext context) {
    final bool anyActive = context.select<AppState, bool>((AppState s) => s.workflows.any((Workflow w) => w.enabled));
    if (!anyActive) return const SizedBox.shrink();
    final TextTheme t = Theme.of(context).textTheme;
    return FutureBuilder<_Report>(
      future: _report,
      builder: (BuildContext context, AsyncSnapshot<_Report> snap) {
        final _Report? r = snap.data;
        if (r == null) return const SizedBox.shrink();
        final List<GuardianFinding> fs = r.findings;
        final bool cloudGap = r.cloudRelevant && !r.cloudChecked;
        return Padding(
          padding: const EdgeInsets.only(bottom: AutometaSpacing.md),
          child: Panel(
            key: const Key('guardian.panel'),
            glow: fs.isEmpty ? null : findingColor(fs.first.severity),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Row(children: <Widget>[
                const Icon(Icons.shield_outlined, size: 18, color: AutometaColors.accent),
                const SizedBox(width: AutometaSpacing.sm),
                Expanded(child: Text('GUARDIAN', style: t.labelLarge?.copyWith(letterSpacing: 1.2))),
                IconButton(
                  tooltip: 'Check again',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => setState(() => _report = _load()),
                ),
              ]),
              Text(
                fs.isEmpty
                    ? (cloudGap ? 'Nothing needs attention on this device.' : 'Nothing needs your attention right now.')
                    : '${fs.length} ${fs.length == 1 ? 'thing needs' : 'things need'} your attention',
                key: const Key('guardian.headline'),
                style: t.titleMedium,
              ),
              if (cloudGap)
                Padding(
                  padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                  child: Text('Cloud automations couldn\'t be checked (signed out or offline).', style: t.bodySmall),
                ),
              for (final GuardianFinding f in fs.take(3)) _FindingRow(f, onTap: () => _open(f)),
              if (fs.length > 3)
                Padding(
                  padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                  child: Text('+ ${fs.length - 3} more. Open each automation to review.', style: t.bodySmall),
                ),
            ]),
          ),
        );
      },
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow(this.f, {required this.onTap});
  final GuardianFinding f;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final Color c = findingColor(f.severity);
    final String where = f.isCloud ? '☁ Cloud' : '📱 On this device';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AutometaSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(c)),
          const SizedBox(width: AutometaSpacing.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(f.title, style: t.titleSmall),
              if (f.automationName != null) Text('${f.automationName} · $where', style: t.bodySmall),
              if (f.body.isNotEmpty) Text(f.body, style: t.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
              if (!f.certain)
                Text('Looks unusual. This may be expected.', style: t.labelSmall?.copyWith(color: c)),
            ]),
          ),
          const Icon(Icons.chevron_right, size: 18),
        ]),
      ),
    );
  }
}
