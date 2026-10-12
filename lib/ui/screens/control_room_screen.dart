import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../guardian_scope.dart';
import '../status_label.dart';
import 'approval_sheet.dart';
import 'business/business_shell.dart';
import 'execution_detail_screen.dart';
import 'notification_center_screen.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/autometa_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/engine/approval_request.dart';
import '../../domain/health/guardian.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../../domain/models/step.dart';
import '../../domain/schedule/schedule_calculator.dart';
import '../../services/connections/connection_manager.dart';
import '../../services/connections/connection_state.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import '../widgets/floating_nav_dock.dart';
import '../widgets/guardian_panel.dart';
import '../widgets/message_ready_card.dart';

// ---------------------------------------------------------------------------
// View models. The dashboard is pure presentation over these, so it can be
// driven straight from a test without the whole service graph.
// ---------------------------------------------------------------------------

@immutable
class ControlRoomConnection {
  const ControlRoomConnection({
    required this.name,
    required this.detail,
    required this.ok,
  });

  final String name;
  final String detail;
  final bool ok;
}

@immutable
class ControlRoomNextRun {
  const ControlRoomNextRun({
    required this.time,
    required this.name,
    required this.preview,
    required this.relative,
  });

  final String time;
  final String name;
  final String preview;
  final String relative;
}

@immutable
class ControlRoomSlot {
  const ControlRoomSlot({
    required this.id,
    required this.name,
    required this.time,
    required this.icon,
    required this.color,
    this.statusLabel,
  });

  final String id;
  final String name;
  final String time;
  final IconData icon;
  final Color color;
  final String? statusLabel;
}

@immutable
class ControlRoomRun {
  const ControlRoomRun({
    required this.id,
    required this.name,
    required this.statusLabel,
    required this.color,
    required this.when,
  });

  final String id;
  final String name;
  final String statusLabel;
  final Color color;
  final String when;
}

@immutable
class ControlRoomApproval {
  const ControlRoomApproval({
    required this.id,
    required this.title,
    required this.isWhatsAppHandoff,
  });

  final String id;
  final String title;
  final bool isWhatsAppHandoff;
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

/// The AUTOMETA Control Room: the landing dashboard.
///
/// State of the whole system in one glance — engine state, what needs
/// attention, the next thing that will fire, today's timeline, recent runs and
/// connection health — with Guardian's live findings and the Notification
/// Center badge wired to the same Guardian pass.
class ControlRoomScreen extends StatefulWidget {
  const ControlRoomScreen({super.key});

  @override
  State<ControlRoomScreen> createState() => _ControlRoomScreenState();
}

class _ControlRoomScreenState extends State<ControlRoomScreen> {
  @override
  Widget build(BuildContext context) {
    final AppState state = context.watch<AppState>();
    final ConnectionManager connections = context.watch<ConnectionManager>();
    final CloudSession cloud = context.watch<CloudSession>();
    final GuardianScope? scope = GuardianScope.maybeOf(context);
    final DateTime now = DateTime.now();

    final List<GuardianFinding> findings =
        scope?.snapshot?.findings ?? const <GuardianFinding>[];
    final int critical = findings
        .where((GuardianFinding f) => f.severity == FindingSeverity.critical)
        .length;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await state.refresh();
            if (scope != null) await scope.onRefresh();
          },
          child: ControlRoomView(
            greeting: Formatters.greeting(now),
            paused: state.isPaused,
            activeCount: state.activeCount,
            failureCount: state.failureCount,
            slotsToday: state.todaySlots.length,
            runsToday:
                state.todaySlots.where((ScheduledSlot s) => s.execution != null).length,
            attentionCount: findings.length,
            criticalCount: critical,
            unreadCount: scope?.unreadCount ?? 0,
            findings: findings,
            cloudGap: scope?.snapshot?.cloudGap ?? false,
            notEnoughHistory: scope?.snapshot?.notEnoughHistory ?? false,
            connections: <ControlRoomConnection>[
              for (final ConnectionRecord r in connections.records)
                ControlRoomConnection(
                  name: _serviceName(r.service),
                  detail: r.status.label,
                  ok: r.status.isUsable,
                ),
              ControlRoomConnection(
                name: 'Cloud',
                detail: cloud.signedIn ? 'Signed in' : 'Not signed in',
                ok: cloud.signedIn,
              ),
            ],
            nextRun: _nextRun(state),
            today: <ControlRoomSlot>[
              for (final ScheduledSlot s in state.todaySlots) _slot(s),
            ],
            recent: <ControlRoomRun>[
              for (final ExecutionRecord r in state.recentExecutions.take(5)) _run(r, now),
            ],
            approvals: <ControlRoomApproval>[
              for (final ApprovalTicket t in state.pendingApprovals)
                ControlRoomApproval(
                  id: t.id,
                  title: t.title,
                  isWhatsAppHandoff: isWhatsAppHandoff(t),
                ),
            ],
            onResume: () => state.setPaused(false),
            onOpenNotifications: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const NotificationCenterScreen(),
                ),
              );
              if (mounted && scope != null) await scope.onRefresh();
            },
            onOpenExecution: _openExecution,
            onNewAutomation: () => AppShell.newAutomation(context),
            onOpenBusiness: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const BusinessGate()),
                ),
            onOpenFinding: (GuardianFinding f) async {
              await openGuardianTarget(
                context,
                workflowId: f.workflowId,
                cloudAutomationId: f.cloudAutomationId,
                connectionId: f.connectionId,
              );
              if (mounted && scope != null) await scope.onRefresh();
            },
            onRefreshGuardian: scope == null ? null : () => scope.onRefresh(),
            onApprove: (ControlRoomApproval a) async {
              final ExecutionRecord? r =
                  await state.resolveApproval(a.id, approved: true);
              if (!mounted) return;
              showToast(
                context,
                r == null ? 'Could not open WhatsApp' : honestStatusLabel(r),
              );
            },
            onSkip: (ControlRoomApproval a) =>
                state.resolveApproval(a.id, approved: false),
            onOpenApproval: (ControlRoomApproval a) {
              for (final ApprovalTicket t in state.pendingApprovals) {
                if (t.id == a.id) {
                  showApprovalSheet(context, t);
                  return;
                }
              }
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openExecution(ControlRoomRun run) async {
    final AppState state = context.read<AppState>();
    for (final ExecutionRecord r in state.recentExecutions) {
      if (r.id == run.id) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => ExecutionDetailScreen(record: r),
          ),
        );
        return;
      }
    }
  }

  static ControlRoomNextRun? _nextRun(AppState state) {
    final WorkflowRun? run = state.nextRun;
    if (run == null) return null;
    String preview = '';
    for (final WorkflowStep s in run.workflow.steps) {
      if (s is WhatsAppStep) {
        preview = s.message;
        break;
      }
      if (s is NotificationStep) {
        preview = s.body;
        break;
      }
    }
    final DateTime at = run.at.toLocal();
    return ControlRoomNextRun(
      time: Formatters.time(at),
      name: run.workflow.name,
      preview: preview.isEmpty ? run.workflow.name : Formatters.preview(preview),
      relative: Formatters.relative(at),
    );
  }

  static ControlRoomSlot _slot(ScheduledSlot s) {
    final ExecutionRecord? run = s.execution;
    final IconData icon;
    if (run == null) {
      icon = Icons.radio_button_unchecked;
    } else {
      icon = switch (run.status) {
        ExecutionStatus.success => Icons.check_circle,
        ExecutionStatus.failed => Icons.error_outline,
        _ => Icons.schedule,
      };
    }
    return ControlRoomSlot(
      id: s.workflow.id,
      name: s.workflow.name,
      time: Formatters.time24(s.at.toLocal()),
      icon: icon,
      color: run == null ? AutometaColors.neutral : statusColor(run.status),
      statusLabel: run == null ? null : honestStatusLabel(run),
    );
  }

  static ControlRoomRun _run(ExecutionRecord r, DateTime now) => ControlRoomRun(
        id: r.id,
        name: r.workflowName,
        statusLabel: honestStatusLabel(r),
        color: statusColor(r.status),
        when: Formatters.relative((r.startedAt ?? now).toLocal()),
      );

  static String _serviceName(String service) {
    if (service.isEmpty) return service;
    return service[0].toUpperCase() + service.substring(1);
  }
}

// ---------------------------------------------------------------------------
// Presentation
// ---------------------------------------------------------------------------

/// Pure presentation of the Control Room (tested directly).
class ControlRoomView extends StatelessWidget {
  const ControlRoomView({
    required this.greeting,
    required this.paused,
    required this.activeCount,
    required this.failureCount,
    required this.slotsToday,
    required this.runsToday,
    required this.attentionCount,
    required this.criticalCount,
    required this.unreadCount,
    required this.findings,
    required this.connections,
    required this.nextRun,
    required this.today,
    required this.recent,
    required this.approvals,
    required this.onNewAutomation,
    required this.onOpenNotifications,
    this.cloudGap = false,
    this.notEnoughHistory = false,
    this.onResume,
    this.onOpenBusiness,
    this.onOpenExecution,
    this.onApprove,
    this.onSkip,
    this.onOpenApproval,
    this.onOpenFinding,
    this.onRefreshGuardian,
    super.key,
  });

  final String greeting;
  final bool paused;
  final int activeCount;
  final int failureCount;
  final int slotsToday;
  final int runsToday;
  final int attentionCount;
  final int criticalCount;
  final int unreadCount;

  /// Guardian findings from the shell's pass; rendered by the same widget the
  /// old Home screen used, so the dashboard and the inbox agree.
  final List<GuardianFinding> findings;
  final bool cloudGap;
  final bool notEnoughHistory;

  final List<ControlRoomConnection> connections;
  final ControlRoomNextRun? nextRun;
  final List<ControlRoomSlot> today;
  final List<ControlRoomRun> recent;
  final List<ControlRoomApproval> approvals;

  final VoidCallback onNewAutomation;
  final VoidCallback onOpenNotifications;
  final VoidCallback? onResume;
  final VoidCallback? onOpenBusiness;
  final ValueChanged<ControlRoomRun>? onOpenExecution;
  final ValueChanged<ControlRoomApproval>? onApprove;
  final ValueChanged<ControlRoomApproval>? onSkip;
  final ValueChanged<ControlRoomApproval>? onOpenApproval;
  final ValueChanged<GuardianFinding>? onOpenFinding;
  final Future<void> Function()? onRefreshGuardian;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    // Widest a chip may ever be. Chips are hard-capped rather than left to
    // intrinsic width, so a long status (or 1.8x text) can't overflow.
    final double available =
        MediaQuery.sizeOf(context).width - AutometaSpacing.page(context) * 2;
    final _RoomState room = _RoomState.of(
      paused: paused,
      criticalCount: criticalCount,
      attentionCount: attentionCount,
    );

    return ListView(
      key: const Key('controlRoom.root'),
      padding: EdgeInsets.symmetric(
        horizontal: AutometaSpacing.page(context),
        vertical: AutometaSpacing.lg,
      ),
      children: <Widget>[
        ResponsiveWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // ---- header -------------------------------------------------
              // Explicit glyph + flexible wordmark + fixed bell. A
              // mainAxisSize.min wordmark pushes the bell off a 320dp screen
              // once the system text scale reaches ~1.8x.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  const AutometaGlyph(size: 24),
                  const SizedBox(width: AutometaSpacing.sm),
                  Expanded(
                    child: Text(
                      'AUTOMETA',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleLarge?.copyWith(
                        letterSpacing: 3.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: AutometaSpacing.sm),
                  _NotificationBell(
                    unreadCount: unreadCount,
                    onOpen: onOpenNotifications,
                  ),
                ],
              ),
              const SizedBox(height: AutometaSpacing.lg),
              Text(
                greeting,
                key: const Key('controlRoom.greeting'),
                style: t.headlineMedium,
              ),

              // ---- hero ---------------------------------------------------
              const SizedBox(height: AutometaSpacing.lg),
              Panel(
                key: const Key('controlRoom.hero'),
                glow: room.color,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        StatusDot(room.color, size: 9, pulse: !paused),
                        const SizedBox(width: AutometaSpacing.sm),
                        Expanded(
                          child: Text(
                            'CONTROL ROOM',
                            style: t.labelLarge?.copyWith(
                              letterSpacing: 1.6,
                              color: colors.textTertiary,
                            ),
                          ),
                        ),
                        Text(
                          room.label,
                          key: const Key('controlRoom.state'),
                          style: t.labelLarge?.copyWith(color: room.color),
                        ),
                      ],
                    ),
                    const SizedBox(height: AutometaSpacing.md),
                    Text(
                      room.headline,
                      key: const Key('controlRoom.headline'),
                      style: t.displaySmall?.copyWith(color: room.color, fontSize: 26),
                    ),
                    const SizedBox(height: AutometaSpacing.xs),
                    Text(room.detail, style: t.bodyMedium),
                    if (paused) ...<Widget>[
                      const SizedBox(height: AutometaSpacing.md),
                      OutlinedButton(
                        key: const Key('controlRoom.resume'),
                        onPressed: onResume,
                        child: const Text('Resume automations'),
                      ),
                    ],
                  ],
                ),
              ),

              // ---- metrics ------------------------------------------------
              const SizedBox(height: AutometaSpacing.md),
              _MetricRow(
                left: _Metric(
                  key: const Key('controlRoom.metric.active'),
                  label: 'Active',
                  value: '$activeCount',
                  color: AutometaColors.accent,
                  icon: Icons.bolt_outlined,
                ),
                right: _Metric(
                  key: const Key('controlRoom.metric.attention'),
                  label: 'Needs you',
                  value: '$attentionCount',
                  color: attentionCount > 0 ? room.color : colors.textTertiary,
                  icon: Icons.shield_outlined,
                ),
              ),
              const SizedBox(height: AutometaSpacing.md),
              _MetricRow(
                left: _Metric(
                  key: const Key('controlRoom.metric.today'),
                  label: 'Ran today',
                  value: '$runsToday/$slotsToday',
                  color: AutometaColors.info,
                  icon: Icons.today_outlined,
                ),
                right: _Metric(
                  key: const Key('controlRoom.metric.failures'),
                  label: 'Failures',
                  value: '$failureCount',
                  color: failureCount > 0 ? AutometaColors.danger : colors.textTertiary,
                  icon: Icons.error_outline,
                ),
              ),

              // ---- approvals ----------------------------------------------
              for (final ControlRoomApproval a in approvals) ...<Widget>[
                const SizedBox(height: AutometaSpacing.md),
                Panel(
                  key: Key('controlRoom.approval.${a.id}'),
                  glow: AutometaColors.secondary,
                  accentLeft: true,
                  onTap: onOpenApproval == null ? null : () => onOpenApproval!(a),
                  child: Row(
                    children: <Widget>[
                      const Icon(
                        Icons.verified_user_outlined,
                        color: AutometaColors.secondary,
                      ),
                      const SizedBox(width: AutometaSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'WAITING FOR APPROVAL',
                              style:
                                  t.labelSmall?.copyWith(color: AutometaColors.secondary),
                            ),
                            Text(a.title, style: t.titleSmall),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ],

              // ---- guardian -----------------------------------------------
              if (activeCount > 0) ...<Widget>[
                const SizedBox(height: AutometaSpacing.lg),
                GuardianFindingsView(
                  findings: findings,
                  cloudGap: cloudGap,
                  notEnoughHistory: notEnoughHistory,
                  onOpen: (GuardianFinding f) => onOpenFinding?.call(f),
                  onRefresh: onRefreshGuardian == null
                      ? null
                      : () {
                          onRefreshGuardian!();
                        },
                  limit: kGuardianHomeLimit,
                ),
              ],

              // ---- next run -------------------------------------------------
              const SizedBox(height: AutometaSpacing.md),
              _NextRunPanel(nextRun: nextRun),

              // ---- today ----------------------------------------------------
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Today'),
              if (today.isEmpty)
                Panel(
                  key: const Key('controlRoom.today.empty'),
                  child: Text('Nothing scheduled today.', style: t.bodyMedium),
                )
              else
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.sm),
                  child: Column(
                    children: <Widget>[
                      for (final ControlRoomSlot s in today)
                        ListTile(
                          key: Key('controlRoom.slot.${s.id}'),
                          dense: true,
                          leading: Icon(s.icon, color: s.color, size: 20),
                          title: Text(s.name),
                          subtitle: s.statusLabel == null ? null : Text(s.statusLabel!),
                          trailing: Text(s.time, style: t.labelLarge),
                        ),
                    ],
                  ),
                ),

              // ---- recent ---------------------------------------------------
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Recent'),
              if (recent.isEmpty)
                Panel(
                  key: const Key('controlRoom.recent.empty'),
                  child: Text('No runs yet.', style: t.bodyMedium),
                )
              else
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: AutometaSpacing.sm),
                  child: Column(
                    children: <Widget>[
                      for (final ControlRoomRun r in recent)
                        ListTile(
                          key: Key('controlRoom.run.${r.id}'),
                          dense: true,
                          title: Text(r.name),
                          subtitle: Text(r.when),
                          trailing: _StatusChip(
                            label: r.statusLabel,
                            color: r.color,
                            maxWidth: available * 0.45,
                          ),
                          onTap: onOpenExecution == null
                              ? null
                              : () => onOpenExecution!(r),
                        ),
                    ],
                  ),
                ),

              // ---- connections ----------------------------------------------
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Connections'),
              if (connections.isEmpty)
                Panel(child: Text('No connections yet.', style: t.bodyMedium))
              else
                Wrap(
                  spacing: AutometaSpacing.sm,
                  runSpacing: AutometaSpacing.sm,
                  children: <Widget>[
                    for (final ControlRoomConnection c in connections)
                      _StatusChip(
                        key: Key('controlRoom.connection.${c.name}'),
                        label: '${c.name} · ${c.detail}',
                        color: c.ok ? AutometaColors.success : AutometaColors.neutral,
                        icon: Icons.circle,
                        maxWidth: available,
                      ),
                  ],
                ),

              // ---- actions ---------------------------------------------------
              const SizedBox(height: AutometaSpacing.xl),
              PrimaryAction(
                label: activeCount == 0 ? 'Create your first automation' : 'New automation',
                icon: Icons.add,
                onPressed: onNewAutomation,
              ),
              if (onOpenBusiness != null) ...<Widget>[
                const SizedBox(height: AutometaSpacing.lg),
                Panel(
                  glow: AutometaColors.secondary,
                  onTap: onOpenBusiness,
                  child: const Row(
                    children: <Widget>[
                      Icon(Icons.storefront_outlined, color: AutometaColors.secondary),
                      SizedBox(width: AutometaSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Business mode',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              'Auto-reply to customers, take orders, capture leads and share '
                              'the inbox with staff, using the official WhatsApp Business Platform.',
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AutometaSpacing.xl),
            ],
          ),
        ),
      ],
    );
  }
}

/// The single-word state of the room and the copy that goes with it.
class _RoomState {
  const _RoomState(this.label, this.headline, this.detail, this.color);

  final String label;
  final String headline;
  final String detail;
  final Color color;

  factory _RoomState.of({
    required bool paused,
    required int criticalCount,
    required int attentionCount,
  }) {
    if (paused) {
      return const _RoomState(
        'PAUSED',
        'Paused',
        'No automated actions will execute until you resume.',
        AutometaColors.warning,
      );
    }
    if (criticalCount > 0) {
      return _RoomState(
        'ATTENTION',
        '$criticalCount critical',
        'Guardian found something that will keep failing until it is fixed.',
        AutometaColors.danger,
      );
    }
    if (attentionCount > 0) {
      return _RoomState(
        'ATTENTION',
        attentionCount == 1 ? '1 thing needs you' : '$attentionCount things need you',
        'Guardian flagged something worth a look. Nothing is broken yet.',
        AutometaColors.warning,
      );
    }
    return const _RoomState(
      'OPERATIONAL',
      'All systems go',
      'Automation engine ready. Everything that should run is running.',
      AutometaColors.success,
    );
  }
}

class _NextRunPanel extends StatelessWidget {
  const _NextRunPanel({required this.nextRun});

  final ControlRoomNextRun? nextRun;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Panel(
      key: const Key('controlRoom.next'),
      glow: AutometaColors.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionLabel('Next automation'),
          if (nextRun == null)
            Text('No scheduled automations', style: t.titleMedium)
          else ...<Widget>[
            Text(
              nextRun!.time,
              style: t.displaySmall?.copyWith(color: AutometaColors.accent, fontSize: 28),
            ),
            const SizedBox(height: AutometaSpacing.xs),
            Text(nextRun!.preview, style: t.titleMedium),
            const SizedBox(height: AutometaSpacing.xs),
            Text('${nextRun!.name} · ${nextRun!.relative}', style: t.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.left, required this.right});

  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) => Row(
        children: <Widget>[
          Expanded(child: left),
          const SizedBox(width: AutometaSpacing.md),
          Expanded(child: right),
        ],
      );
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    super.key,
  });

  final String label;
  final String value;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, size: 15, color: color),
                const SizedBox(width: AutometaSpacing.xs),
                Expanded(
                  child: Text(
                    label.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AutometaSpacing.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
      );
}

/// A pill that cannot overflow: it is hard-capped at [maxWidth] and its label
/// ellipsises instead of pushing past the screen edge.
///
/// The shared [StatusPill] sizes to its intrinsic width, which is right for
/// short fixed labels but overflows a 320dp screen once the system text scale
/// reaches ~1.8x and the label is data-driven (a connection state, or
/// "Handed to WhatsApp — you tap Send").
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    required this.maxWidth,
    this.icon,
    super.key,
  });

  final String label;
  final Color color;
  final double maxWidth;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 12, color: color),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: color, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
}

class _NotificationBell extends StatelessWidget {
  const _NotificationBell({required this.unreadCount, required this.onOpen});

  final int unreadCount;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final bool hasUnread = unreadCount > 0;
    return Semantics(
      button: true,
      label: hasUnread ? 'Notifications, $unreadCount unread' : 'Notifications, none unread',
      excludeSemantics: true,
      child: InkWell(
        key: const Key('controlRoom.bell'),
        onTap: onOpen,
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          width: AutometaSpacing.touchTarget,
          height: AutometaSpacing.touchTarget,
          child: Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Icon(
                  hasUnread ? Icons.notifications_active : Icons.notifications_none,
                  color: hasUnread ? AutometaColors.warning : null,
                ),
                if (hasUnread)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: UnreadBadge(
                      key: const Key('controlRoom.badge'),
                      count: unreadCount,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
