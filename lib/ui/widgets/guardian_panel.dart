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

/// How many findings Home shows before "+ N more" (keeps Home calm).
const int kGuardianHomeLimit = 3;

/// Loads Guardian findings (device + Cloud) and shows [GuardianFindingsView].
/// Hidden entirely when no automation is active: nothing to watch.
class GuardianPanel extends StatefulWidget {
  const GuardianPanel({super.key});

  @override
  State<GuardianPanel> createState() => _GuardianPanelState();
}

class _Report {
  const _Report(this.findings, {required this.cloudGap, required this.notEnoughHistory});
  final List<GuardianFinding> findings;

  /// Active Cloud automations exist but Cloud couldn't be checked.
  final bool cloudGap;

  /// Nothing checked so far has any finished run to judge. "No findings"
  /// would then wrongly read as "all fine".
  final bool notEnoughHistory;
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
    final DateTime now = DateTime.now();
    final List<GuardianFinding> found = GuardianFinding.forDevice(workflows, local, now);
    bool judged = GuardianFinding.deviceHasHistory(workflows, local, now);
    final bool cloudRelevant = workflows.any((Workflow w) => w.isCloud && w.enabled);
    bool cloudChecked = false;
    if (cloud.signedIn) {
      try {
        final Map<String, dynamic> report = await cloud.guardian();
        found.addAll(GuardianFinding.fromCloudReport(report));
        judged = judged || GuardianFinding.cloudHasHistory(report);
        cloudChecked = true;
      } catch (_) {
        cloudChecked = false; // offline / older server: say so, never "all clear"
      }
    }
    return _Report(
      GuardianFinding.sorted(found),
      cloudGap: cloudRelevant && !cloudChecked,
      notEnoughHistory: found.isEmpty && !judged,
    );
  }

  Future<void> _open(GuardianFinding f) async {
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
    if (target == null) {
      // Cloud automation not synced to this phone yet: say so, no dead tap.
      showToast(context, 'This automation isn\'t on this phone yet. Pull down on Home to refresh, then try again.');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => target!));
    // Re-check on return so a fixed problem doesn't linger as a stale finding.
    if (mounted) setState(() => _report = _load());
  }

  @override
  Widget build(BuildContext context) {
    final bool anyActive = context.select<AppState, bool>((AppState s) => s.workflows.any((Workflow w) => w.enabled));
    if (!anyActive) return const SizedBox.shrink();
    return FutureBuilder<_Report>(
      future: _report,
      builder: (BuildContext context, AsyncSnapshot<_Report> snap) {
        final _Report? r = snap.data;
        if (r == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: AutometaSpacing.md),
          child: GuardianFindingsView(
            findings: r.findings,
            cloudGap: r.cloudGap,
            notEnoughHistory: r.notEnoughHistory,
            onOpen: _open,
            onRefresh: () => setState(() => _report = _load()),
          ),
        );
      },
    );
  }
}

/// Pure presentation of Guardian findings (tested directly).
class GuardianFindingsView extends StatelessWidget {
  const GuardianFindingsView({
    required this.findings,
    required this.onOpen,
    this.cloudGap = false,
    this.notEnoughHistory = false,
    this.onRefresh,
    this.limit = kGuardianHomeLimit,
    super.key,
  });

  /// Already ordered (see [GuardianFinding.sorted]).
  final List<GuardianFinding> findings;
  final bool cloudGap;

  /// No active automation has a finished run yet: say so instead of "all fine".
  final bool notEnoughHistory;
  final ValueChanged<GuardianFinding> onOpen;
  final VoidCallback? onRefresh;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final List<GuardianFinding> fs = findings;
    return Panel(
      key: const Key('guardian.panel'),
      glow: fs.isEmpty ? null : findingColor(fs.first.severity),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.shield_outlined, size: 18, color: AutometaColors.accent),
          const SizedBox(width: AutometaSpacing.sm),
          Expanded(child: Text('NEEDS YOUR ATTENTION', style: t.labelLarge?.copyWith(letterSpacing: 1.2))),
          if (onRefresh != null)
            IconButton(
              tooltip: 'Check again',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: onRefresh,
            ),
        ]),
        Text(
          fs.isNotEmpty
              ? '${fs.length} ${fs.length == 1 ? 'thing needs' : 'things need'} your attention'
              : notEnoughHistory
                  ? 'Not enough history yet. Guardian checks automations once they have run.'
                  : (cloudGap ? 'Nothing needs attention on this device.' : 'Nothing needs your attention right now.'),
          key: const Key('guardian.headline'),
          style: t.titleMedium,
        ),
        if (cloudGap)
          Padding(
            padding: const EdgeInsets.only(top: AutometaSpacing.xs),
            child: Text('Cloud automations couldn\'t be checked (signed out, offline, or the server doesn\'t support Guardian yet).',
                key: const Key('guardian.cloudGap'), style: t.bodySmall),
          ),
        for (final GuardianFinding f in fs.take(limit)) _FindingRow(f, onOpen: () => onOpen(f)),
        if (fs.length > limit)
          Padding(
            padding: const EdgeInsets.only(top: AutometaSpacing.xs),
            child: Text('+ ${fs.length - limit} more. Open each automation to review.', key: const Key('guardian.more'), style: t.bodySmall),
          ),
      ]),
    );
  }
}

class _FindingRow extends StatelessWidget {
  const _FindingRow(this.f, {required this.onOpen});
  final GuardianFinding f;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final Color c = findingColor(f.severity);
    final String subject = f.automationName ?? (f.connectionId != null ? 'Connection' : '');
    final String where = f.isCloud ? '☁ Cloud' : '📱 On this device';
    return Padding(
      key: Key('guardian.finding.${f.kind}.${f.workflowId ?? f.cloudAutomationId ?? f.connectionId}'),
      padding: const EdgeInsets.only(top: AutometaSpacing.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Padding(padding: const EdgeInsets.only(top: 6), child: StatusDot(c)),
        const SizedBox(width: AutometaSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (subject.isNotEmpty) Text(subject, style: t.titleSmall),
            Text(f.title, style: t.bodyMedium?.copyWith(color: c)),
            if (f.body.isNotEmpty) Text(f.body, style: t.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (f.why.isNotEmpty) Text(f.why, style: t.bodySmall),
            if (!f.certain) Text('Looks unusual. This may be expected.', style: t.labelSmall?.copyWith(color: c)),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: AutometaSpacing.sm,
              children: <Widget>[
                Text(where, style: t.labelSmall),
                TextButton(
                  key: Key('guardian.action.${f.kind}'),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  onPressed: onOpen,
                  child: Text(f.actionLabel ?? 'View'),
                ),
              ],
            ),
          ]),
        ),
      ]),
    );
  }
}
