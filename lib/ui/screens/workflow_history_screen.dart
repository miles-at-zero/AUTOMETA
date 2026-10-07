import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/capabilities/execution_capabilities.dart';
import '../../domain/health/automation_health.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_mode.dart';
import '../../domain/models/step.dart';
import '../../domain/models/workflow.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import '../widgets/execution_widgets.dart';
import '../widgets/health_panel.dart';
import 'builder_screen.dart';
import 'cloud_account_screen.dart';
import 'cloud_execution_screen.dart';
import 'execution_detail_screen.dart';
import 'home_screen.dart';

/// Automation detail: execution mode (+ migration), WHEN / IF / DO, status,
/// next run, history from wherever it ran, and errors.
class AutomationDetailScreen extends StatefulWidget {
  const AutomationDetailScreen({required this.workflow, super.key});
  final Workflow workflow;

  @override
  State<AutomationDetailScreen> createState() => _AutomationDetailScreenState();
}

/// Kept for existing call sites.
typedef WorkflowHistoryScreen = AutomationDetailScreen;

class _AutomationDetailScreenState extends State<AutomationDetailScreen> {
  Future<List<ExecutionRecord>>? _local;
  Future<Json?>? _cloud;

  /// Real runs for health, from where this automation actually runs: Cloud
  /// rows for Cloud automations, device records for on-device ones. Null when
  /// that history can't be read (e.g. signed out / offline for Cloud).
  Future<List<RunSample>?>? _samples;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Workflow get _w {
    final AppState s = context.read<AppState>();
    return s.workflows.firstWhere((Workflow w) => w.id == widget.workflow.id, orElse: () => widget.workflow);
  }

  void _load() {
    final Workflow w = widget.workflow;
    _local = context.read<AppServices>().executions.forWorkflow(w.id);
    final CloudSession c = context.read<CloudSession>();
    final String? id = _currentCloudId();
    _cloud = id != null && c.signedIn ? c.detail(id).then<Json?>((Json j) => j) : Future<Json?>.value();
    final bool cloudMode = _w.isCloud;
    final Future<List<ExecutionRecord>> local = _local!;
    final Future<Json?> cloud = _cloud!;
    _samples = () async {
      if (!cloudMode) {
        return (await local).map(RunSample.fromRecord).whereType<RunSample>().toList();
      }
      try {
        final Json? d = await cloud;
        if (d == null) return null;
        return asList(d['recent']).map(RunSample.fromCloud).whereType<RunSample>().toList();
      } catch (_) {
        return null;
      }
    }();
  }

  String? _currentCloudId() {
    final AppState s = context.read<AppState>();
    return s.workflows.firstWhere((Workflow w) => w.id == widget.workflow.id, orElse: () => widget.workflow).cloudId;
  }

  Future<void> _move(Workflow w, ExecutionMode to) async {
    final AppState state = context.read<AppState>();
    setState(() => _busy = true);
    final MoveResult r = to.isCloud ? await state.moveToCloud(w) : await state.moveToDevice(w);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _load();
    });
    if (r.ok) {
      showToast(context, r.message);
    } else if (r.needsAccount) {
      final bool go = await confirmDialog(context, title: 'Sign in to Cloud', message: r.message, confirmLabel: 'Sign in');
      if (go && mounted) await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen()));
    } else if (r.issues.isNotEmpty) {
      final String? choice = await showMoveBlockedSheet(context,
          title: to.isCloud ? 'Cannot move to Cloud' : 'Cannot move to this device',
          message: r.message,
          issues: r.issues,
          keepLabel: to.isCloud ? 'Keep On-device' : 'Keep in Cloud');
      if (choice == 'edit' && mounted) {
        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BuilderScreen(initial: w)));
      }
    } else {
      showToast(context, r.message, color: AutometaColors.danger.withValues(alpha: 0.3));
    }
  }

  Future<void> _runNow(Workflow w) async {
    try {
      final ExecutionRecord? r = await context.read<AppState>().runNow(w.id);
      if (!mounted) return;
      showToast(context, w.isCloud ? 'Started in Cloud. The result appears in History.' : (r == null ? 'Could not run' : honestStatusLabel(r)));
      setState(_load);
    } on CloudException catch (e) {
      if (mounted) showToast(context, e.message, color: AutometaColors.danger.withValues(alpha: 0.3));
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<AppState>();
    final Workflow w = _w;
    final TextTheme t = Theme.of(context).textTheme;
    final List<CapabilityIssue> cloudIssues = ExecutionCapabilities.check(w, ExecutionMode.cloud);
    final List<CapabilityIssue> modeIssues = ExecutionCapabilities.check(w, w.executionMode);
    final bool canMoveToDevice = w.isCloud && ExecutionCapabilities.check(w, ExecutionMode.onDevice).isEmpty;
    final DateTime? localNext = w.runsLocally ? context.read<AppServices>().calculator.nextOccurrence(w) : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(w.name),
        actions: <Widget>[
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BuilderScreen(initial: w))),
          ),
          PopupMenuButton<String>(
            onSelected: (String a) {
              if (a == 'run') _runNow(w);
              if (a == 'refresh') setState(_load);
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'run', child: Text('Run now')),
              PopupMenuItem<String>(value: 'refresh', child: Text('Refresh')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => setState(_load),
        child: ListView(
          padding: EdgeInsets.all(AutometaSpacing.page(context)),
          children: <Widget>[
            ResponsiveWidth(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: <Widget>[
                  StatusPill(
                    label: modeIssues.isNotEmpty ? 'Needs attention' : (w.enabled ? 'Active' : 'Draft / paused'),
                    color: modeIssues.isNotEmpty ? AutometaColors.warning : (w.enabled ? AutometaColors.success : AutometaColors.neutral),
                    filled: true,
                  ),
                  AutometaExecutionBadge(
                    mode: w.executionMode,
                    state: modeIssues.isNotEmpty
                        ? ExecutionBadgeState.needsAttention
                        : (w.isCloud ? ExecutionBadgeState.recommended : ExecutionBadgeState.normal),
                  ),
                ]),
                const SizedBox(height: AutometaSpacing.lg),

                // Health: computed from real runs only (see AutomationHealth).
                FutureBuilder<List<RunSample>?>(
                  future: _samples,
                  builder: (BuildContext context, AsyncSnapshot<List<RunSample>?> snap) {
                    if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: AutometaSpacing.lg),
                      child: HealthPanel(
                        health: snap.data == null
                            ? null
                            : AutomationHealth.evaluate(
                                enabled: w.enabled,
                                runs: snap.data!,
                                now: DateTime.now(),
                                configIssues: <String>[for (final CapabilityIssue i in modeIssues) '${i.label}: ${i.reason}'],
                              ),
                        isCloud: w.isCloud,
                      ),
                    );
                  },
                ),

                // Execution
                Panel(
                  glow: w.isCloud ? AutometaColors.accent : null,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text('EXECUTION', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
                    const SizedBox(height: 4),
                    Text(w.isCloud ? 'Cloud • Recommended' : 'On this device', style: t.titleMedium),
                    const SizedBox(height: 4),
                    Text(w.isCloud
                        ? 'Runs on the Autometa server, even when the app is closed or your phone is offline.'
                        : ExecutionCopy.recommendation),
                    const SizedBox(height: 10),
                    if (!w.isCloud)
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _move(w, ExecutionMode.cloud),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: Text(cloudIssues.isEmpty ? 'Move to Cloud' : 'Move to Cloud (needs attention)'),
                      ),
                    if (canMoveToDevice)
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _move(w, ExecutionMode.onDevice),
                        icon: const Icon(Icons.smartphone),
                        label: const Text('Move to this device'),
                      ),
                  ]),
                ),
                const SizedBox(height: AutometaSpacing.lg),

                // WHEN / IF / DO
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    Text('WHEN', style: t.labelLarge?.copyWith(color: AutometaColors.accent, letterSpacing: 1.2)),
                    Text(w.trigger.describe(), style: t.bodyLarge),
                    if (localNext != null) Text('Next run: ${Formatters.stamp(localNext.toLocal())}', style: t.bodySmall),
                    const SizedBox(height: 10),
                    for (final WorkflowStep s in w.steps) _StepLine(step: s, mode: w.executionMode),
                    for (final CapabilityIssue i in modeIssues)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('⚠ ${i.label}: ${i.reason}', style: t.bodySmall?.copyWith(color: AutometaColors.warning)),
                      ),
                  ]),
                ),
                const SizedBox(height: AutometaSpacing.lg),

                // Cloud status + history
                if (w.isCloud || w.cloudId != null)
                  FutureBuilder<Json?>(
                    future: _cloud,
                    builder: (BuildContext context, AsyncSnapshot<Json?> snap) {
                      if (snap.connectionState != ConnectionState.done) return const LinearProgressIndicator();
                      if (snap.hasError) {
                        final Object e = snap.error!;
                        final bool offline = e is CloudException && e.offline;
                        return Panel(
                          child: Text(offline
                              ? 'You\'re offline. Cloud automations keep running on the server; new results appear when you\'re back online.'
                              : 'Couldn\'t load Cloud history: $e'),
                        );
                      }
                      final Json? d = snap.data;
                      if (d == null) {
                        return Panel(
                          child: Text(context.read<CloudSession>().signedIn
                              ? 'Not synced to Cloud yet. Activate it to start running on the server.'
                              : 'Sign in to Autometa Cloud to see Cloud runs.'),
                        );
                      }
                      final List<Json> recent = asList(d['recent']);
                      final String? next = d['nextRunAt'] == null ? null : Formatters.stamp(DateTime.fromMillisecondsSinceEpoch(intOf(d['nextRunAt'])));
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                        Text('☁️ CLOUD RUNS', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
                        if (next != null) Text('Next run: $next', style: t.bodySmall),
                        if (d['statusReason'] != null) Text(str(d['statusReason']), style: t.bodySmall?.copyWith(color: AutometaColors.warning)),
                        if (recent.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No Cloud runs yet.')),
                        for (final Json e in recent)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: StatusDot(_cloudColor(str(e['status']))),
                            title: Text('☁️ ${_cloudLabel(str(e['status']))}${e['isTest'] == 1 || e['isTest'] == true ? ' · test' : ''}'),
                            subtitle: Text([
                              Formatters.stamp(DateTime.fromMillisecondsSinceEpoch(intOf(e['startedAt']))),
                              if (e['error'] != null) str(e['error']),
                            ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CloudExecutionScreen(executionId: str(e['id'])))),
                          ),
                        const SizedBox(height: AutometaSpacing.lg),
                      ]);
                    },
                  ),

                // Local history
                FutureBuilder<List<ExecutionRecord>>(
                  future: _local,
                  builder: (BuildContext context, AsyncSnapshot<List<ExecutionRecord>> snap) {
                    final List<ExecutionRecord> items = snap.data ?? <ExecutionRecord>[];
                    if (snap.connectionState != ConnectionState.done) return const SizedBox.shrink();
                    if (items.isEmpty && w.isCloud) return const SizedBox.shrink();
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
                      Text('📱 RUNS ON THIS DEVICE', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
                      if (items.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('This automation has not run on this device.')),
                      for (final ExecutionRecord r in items)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: StatusDot(statusColor(r.status)),
                          title: Text('📱 ${honestStatusLabel(r)}'),
                          subtitle: Text([
                            Formatters.stamp(r.scheduledFor.toLocal()),
                            if (r.failureReason != null) r.failureReason!,
                          ].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: r))),
                        ),
                    ]);
                  },
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

String _cloudLabel(String s) => switch (s) {
      'success' => 'Success',
      'running' => 'Running',
      'failed' => 'Failed',
      'partial' => 'Partly done',
      'cancelled' => 'Cancelled',
      'skipped' => 'Skipped',
      _ => s,
    };

Color _cloudColor(String s) => switch (s) {
      'success' => AutometaColors.success,
      'running' => AutometaColors.accent,
      'failed' || 'partial' => AutometaColors.danger,
      _ => AutometaColors.neutral,
    };

class _StepLine extends StatelessWidget {
  const _StepLine({required this.step, required this.mode});
  final WorkflowStep step;
  final ExecutionMode mode;

  @override
  Widget build(BuildContext context) {
    final bool ok = ExecutionCapabilities.step(step).supports(mode);
    final String kicker = step is ConditionStep ? 'IF' : (step is DelayStep ? 'WAIT' : 'DO');
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        SizedBox(width: 44, child: Text(kicker, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AutometaColors.secondary))),
        Expanded(child: Text(ExecutionCapabilities.stepTitle(step))),
        Icon(ok ? Icons.check_circle_outline : Icons.block, size: 16, color: ok ? AutometaColors.success : AutometaColors.warning),
      ]),
    );
  }
}
