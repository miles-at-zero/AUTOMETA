import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/autometa_theme.dart';
import '../core/theme/design_tokens.dart';
import '../core/utils/formatters.dart';
import '../domain/health/guardian.dart';
import '../domain/notifications/notification_center.dart';
import '../services/settings/settings_service.dart';
import '../guardian_scope.dart';
import '../widgets/autometa_widgets.dart';
import '../widgets/guardian_panel.dart';

/// The Guardian Notification Center.
///
/// Every row comes from a live Guardian pass, so the inbox can never keep
/// warning about something that is already fixed. What *is* remembered is the
/// user's own state — read and dismissed — and Guardian's findings are
/// de-duplicated onto a stable identity so a refresh never re-adds a
/// notification the user has already dealt with.
class NotificationCenterScreen extends StatefulWidget {
  const NotificationCenterScreen({super.key});

  @override
  State<NotificationCenterScreen> createState() => _NotificationCenterScreenState();
}

class _NotificationCenterScreenState extends State<NotificationCenterScreen> {
  NotificationFilter _filter = NotificationFilter.all;

  /// Only used when the screen is opened outside the navigation shell (e.g. a
  /// deep link in a test). Inside the shell, the pass already ran once and the
  /// inbox comes from [GuardianScope].
  GuardianInboxController? _own;
  SettingsService? _settings;
  bool _ownLoaded = false;

  @override
  void initState() {
    super.initState();
    if (GuardianScope.maybeOf(context) == null) {
      _own = GuardianInboxController();
      _settings = context.read<SettingsService>();
      unawaited(_loadOwn());
    }
  }

  Future<void> _loadOwn() async {
    await _own!.load(context, _settings!);
    if (!mounted) return;
    setState(() => _ownLoaded = true);
  }

  /// Applies a user action through the shell when there is one, so the dock
  /// badge and the dashboard update at the same moment as this screen.
  void _apply(GuardianScope? scope, NotificationCenter next) {
    if (scope != null) {
      scope.onChanged(next);
      return;
    }
    setState(() => _own!.center = next);
    unawaited(_own!.persist(_settings!));
  }

  Future<void> _open(GuardianScope? scope, NotificationCenter center, NotificationEntry entry) async {
    await openGuardianTarget(
      context,
      workflowId: entry.workflowId,
      cloudAutomationId: entry.cloudAutomationId,
      connectionId: entry.connectionId,
    );
    if (!mounted) return;
    // Mark it read, then re-run the pass so a fix made behind that screen is
    // reflected immediately instead of lingering as a stale warning.
    _apply(scope, center.markRead(entry.key));
    if (scope != null) {
      await scope.onRefresh();
    } else {
      await _loadOwn();
    }
  }

  @override
  Widget build(BuildContext context) {
    final GuardianScope? scope = GuardianScope.maybeOf(context);
    final bool ready = scope != null ? scope.loaded : _ownLoaded;
    if (!ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final GuardianSnapshot snapshot = scope?.snapshot ??
        _own?.snapshot ??
        const GuardianSnapshot(<GuardianFinding>[], cloudGap: false, notEnoughHistory: false);
    final NotificationCenter center = scope?.center ?? _own!.center;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NOTIFICATIONS'),
        actions: <Widget>[
          IconButton(
            key: const Key('nc.refresh'),
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh),
            onPressed: () => scope != null ? scope.onRefresh() : _loadOwn(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => scope != null ? scope.onRefresh() : _loadOwn(),
        child: NotificationCenterView(
          center: center,
          filter: _filter,
          cloudGap: snapshot.cloudGap,
          notEnoughHistory: snapshot.notEnoughHistory,
          onFilterChanged: (NotificationFilter f) => setState(() => _filter = f),
          onOpen: (NotificationEntry e) => _open(scope, center, e),
          onDismiss: (NotificationEntry e) => _apply(scope, center.dismiss(e.key)),
          onMarkAllRead: () => _apply(scope, center.markAllRead()),
        ),
      ),
    );
  }
}

/// Pure presentation of the inbox (tested directly).
class NotificationCenterView extends StatelessWidget {
  const NotificationCenterView({
    required this.center,
    required this.filter,
    required this.onFilterChanged,
    required this.onOpen,
    required this.onDismiss,
    required this.onMarkAllRead,
    this.cloudGap = false,
    this.notEnoughHistory = false,
    super.key,
  });

  final NotificationCenter center;
  final NotificationFilter filter;

  /// Active Cloud automations exist but Cloud couldn't be checked.
  final bool cloudGap;

  /// Nothing checked has a finished run yet: "no notifications" must not read
  /// as "everything is fine".
  final bool notEnoughHistory;

  final ValueChanged<NotificationFilter> onFilterChanged;
  final ValueChanged<NotificationEntry> onOpen;
  final ValueChanged<NotificationEntry> onDismiss;
  final VoidCallback onMarkAllRead;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final List<NotificationEntry> rows = center.visible(filter);
    final int unread = center.unreadCount;

    return ListView(
      key: const Key('nc.root'),
      padding: EdgeInsets.symmetric(
        horizontal: AutometaSpacing.page(context),
        vertical: AutometaSpacing.lg,
      ),
      children: <Widget>[
        ResponsiveWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // ---- summary ------------------------------------------------
              Panel(
                glow: center.criticalCount > 0 ? AutometaColors.danger : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          unread > 0 ? Icons.notifications_active : Icons.notifications_none,
                          size: 18,
                          color: unread > 0 ? AutometaColors.warning : AutometaColors.accent,
                        ),
                        const SizedBox(width: AutometaSpacing.sm),
                        Expanded(
                          child: Text(
                            'GUARDIAN',
                            style: t.labelLarge?.copyWith(letterSpacing: 1.2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AutometaSpacing.xs),
                    Text(
                      center.isEmpty
                          ? (notEnoughHistory ? 'Not enough history yet' : 'Nothing needs your attention')
                          : '${center.entries.length} ${center.entries.length == 1 ? 'notification' : 'notifications'}'
                              '${unread > 0 ? ' · $unread unread' : ''}',
                      key: const Key('nc.headline'),
                      style: t.titleMedium,
                    ),
                    if (notEnoughHistory && center.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                        child: Text(
                          'Guardian checks automations once they have actually run.',
                          style: t.bodySmall,
                        ),
                      ),
                    if (cloudGap)
                      Padding(
                        padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                        child: Text(
                          'Cloud automations couldn’t be checked (signed out, offline, or the server doesn’t support Guardian yet).',
                          key: const Key('nc.cloudGap'),
                          style: t.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),

              if (center.isEmpty) ...<Widget>[
                const SizedBox(height: AutometaSpacing.xl),
                EmptyState(
                  key: const Key('nc.empty'),
                  icon: Icons.notifications_none,
                  title: 'You’re all caught up',
                  message: notEnoughHistory
                      ? 'Guardian will post here the moment an automation runs into something worth telling you about.'
                      : 'Guardian found nothing that needs you. It keeps watching, and posts here when that changes.',
                ),
              ] else ...<Widget>[
                const SizedBox(height: AutometaSpacing.lg),
                // ---- filter + mark all read ------------------------------
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _FilterChips(
                        filter: filter,
                        allCount: center.countFor(NotificationFilter.all),
                        unreadCount: center.countFor(NotificationFilter.unread),
                        onChanged: onFilterChanged,
                      ),
                    ),
                    const SizedBox(width: AutometaSpacing.sm),
                    TextButton(
                      key: const Key('nc.markAllRead'),
                      onPressed: unread == 0 ? null : onMarkAllRead,
                      child: const Text('Mark all read'),
                    ),
                  ],
                ),
                const SizedBox(height: AutometaSpacing.md),
                for (final NotificationEntry e in rows) ...<Widget>[
                  _NotificationRow(
                    entry: e,
                    onOpen: () => onOpen(e),
                    onDismiss: () => onDismiss(e),
                  ),
                  const SizedBox(height: AutometaSpacing.md),
                ],
                if (rows.isEmpty) ...<Widget>[
                  const SizedBox(height: AutometaSpacing.xl),
                  EmptyState(
                    key: const Key('nc.filteredEmpty'),
                    icon: Icons.done_all,
                    title: 'No unread notifications',
                    message: 'Everything Guardian flagged has been opened. Switch to All to see the full history.',
                  ),
                ],
              ],
              const SizedBox(height: AutometaSpacing.xl),
            ],
          ),
        ),
      ],
    );
  }
}

class _FilterChips extends StatelessWidget {
  const _FilterChips({
    required this.filter,
    required this.allCount,
    required this.unreadCount,
    required this.onChanged,
  });

  final NotificationFilter filter;
  final int allCount;
  final int unreadCount;
  final ValueChanged<NotificationFilter> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: AutometaSpacing.sm,
        children: <Widget>[
          _chip(
            context,
            key: const Key('nc.filter.all'),
            label: 'All ($allCount)',
            selected: filter == NotificationFilter.all,
            onTap: () => onChanged(NotificationFilter.all),
          ),
          _chip(
            context,
            key: const Key('nc.filter.unread'),
            label: 'Unread ($unreadCount)',
            selected: filter == NotificationFilter.unread,
            onTap: () => onChanged(NotificationFilter.unread),
          ),
        ],
      );

  Widget _chip(
    BuildContext context, {
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final Color color =
        selected ? AutometaColors.accent : AutometaSemanticColors.of(context).textTertiary;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AutometaColors.accent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? AutometaColors.accent.withValues(alpha: 0.5)
                  : AutometaSemanticColors.of(context).border,
            ),
          ),
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.entry,
    required this.onOpen,
    required this.onDismiss,
  });

  final NotificationEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final Color c = findingColor(entry.severity);
    return Panel(
      key: Key('nc.entry.${entry.key}'),
      glow: entry.isRead ? null : c,
      accentLeft: !entry.isRead,
      padding: const EdgeInsets.all(AutometaSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: StatusDot(c, size: 9, pulse: !entry.isRead && entry.severity == FindingSeverity.critical),
              ),
              const SizedBox(width: AutometaSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            entry.subject,
                            style: t.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!entry.isRead)
                          Container(
                            key: const Key('nc.unreadDot'),
                            margin: const EdgeInsets.only(left: AutometaSpacing.sm),
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: AutometaColors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    Text(entry.title, style: t.bodyMedium?.copyWith(color: c)),
                    if (entry.body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                        child: Text(entry.body, style: t.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
                      ),
                    if (entry.why.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                        child: Text(entry.why, style: t.bodySmall),
                      ),
                    if (!entry.certain)
                      Padding(
                        padding: const EdgeInsets.only(top: AutometaSpacing.xs),
                        child: Text(
                          'Looks unusual. This may be expected.',
                          style: t.labelSmall?.copyWith(color: c),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AutometaSpacing.sm),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: AutometaSpacing.sm,
            runSpacing: AutometaSpacing.xs,
            children: <Widget>[
              Text(entry.where, style: t.labelSmall),
              Text(Formatters.relative(entry.firstSeenAt), style: t.labelSmall),
              TextButton(
                key: Key('nc.action.${entry.key}'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onOpen,
                child: Text(entry.actionLabel ?? 'View'),
              ),
              TextButton(
                key: Key('nc.dismiss.${entry.key}'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                  foregroundColor: AutometaSemanticColors.of(context).textTertiary,
                ),
                onPressed: onDismiss,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


