import 'package:flutter/foundation.dart';

import '../health/guardian.dart';

/// What an inbox row is about. Guardian findings about a broken connection get
/// their own group so "reconnect" never looks like an automation failure.
enum NotificationCategory { guardian, connection }

/// Inbox filter.
enum NotificationFilter { all, unread }

/// One row in the Guardian Notification Center.
///
/// The inbox is always rebuilt from a live Guardian pass (see
/// [GuardianFinding]); only the user's own state (read / dismissed) is stored.
/// That way a stale notification can never claim a problem that is already
/// fixed, which is the failure mode of a persisted-only inbox.
@immutable
class NotificationEntry {
  const NotificationEntry({
    required this.key,
    required this.kind,
    required this.severity,
    required this.certain,
    required this.title,
    required this.body,
    required this.why,
    required this.isCloud,
    required this.firstSeenAt,
    this.automationName,
    this.workflowId,
    this.cloudAutomationId,
    this.connectionId,
    this.actionLabel,
    this.detectedAt,
    this.isRead = false,
  });

  /// Stable identity: the same problem on the same subject is one notification.
  final String key;
  final String kind;
  final FindingSeverity severity;

  /// false = a heuristic ("looks unusual"); the UI must not present it as fact.
  final bool certain;
  final String title;
  final String body;
  final String why;
  final bool isCloud;

  /// When Guardian first reported this (kept across refreshes, so "2h ago"
  /// doesn't reset every time the screen reloads).
  final DateTime firstSeenAt;

  final String? automationName;
  final String? workflowId;
  final String? cloudAutomationId;
  final String? connectionId;
  final String? actionLabel;
  final DateTime? detectedAt;
  final bool isRead;

  NotificationCategory get category =>
      connectionId != null ? NotificationCategory.connection : NotificationCategory.guardian;

  String get subject => automationName ?? (connectionId != null ? 'Connection' : 'AUTOMETA');

  String get where => isCloud ? '☁ Cloud' : '📱 On this device';

  /// Changes whenever Guardian's wording changes. A dismissed notification
  /// comes back only when this does: that is new information, not a nag.
  String get signature => '$title\x00$body';

  NotificationEntry copyWith({
    String? kind,
    FindingSeverity? severity,
    bool? certain,
    String? title,
    String? body,
    String? why,
    bool? isCloud,
    DateTime? firstSeenAt,
    String? automationName,
    String? workflowId,
    String? cloudAutomationId,
    String? connectionId,
    String? actionLabel,
    DateTime? detectedAt,
    bool? isRead,
  }) =>
      NotificationEntry(
        key: key,
        kind: kind ?? this.kind,
        severity: severity ?? this.severity,
        certain: certain ?? this.certain,
        title: title ?? this.title,
        body: body ?? this.body,
        why: why ?? this.why,
        isCloud: isCloud ?? this.isCloud,
        firstSeenAt: firstSeenAt ?? this.firstSeenAt,
        automationName: automationName ?? this.automationName,
        workflowId: workflowId ?? this.workflowId,
        cloudAutomationId: cloudAutomationId ?? this.cloudAutomationId,
        connectionId: connectionId ?? this.connectionId,
        actionLabel: actionLabel ?? this.actionLabel,
        detectedAt: detectedAt ?? this.detectedAt,
        isRead: isRead ?? this.isRead,
      );
}

/// The Guardian Notification Center: a de-duplicated inbox with the user's
/// read / dismissed state kept separately from Guardian's live output.
///
/// De-duplication is the whole point. Guardian re-derives its findings on every
/// pass, so without a stable identity the same failing automation would put a
/// fresh "unread" row in the inbox on every refresh.
@immutable
class NotificationCenter {
  const NotificationCenter({
    this.entries = const <NotificationEntry>[],
    this.readKeys = const <String>{},
    this.dismissed = const <String, String>{},
  });

  final List<NotificationEntry> entries;

  /// Keys the user has already opened or marked read.
  final Set<String> readKeys;

  /// key -> signature at the time it was dismissed.
  final Map<String, String> dismissed;

  // --------------------------------------------------------------- identity

  /// Stable identity for a finding: kind + where it runs + what it is about.
  static String keyFor(GuardianFinding f) {
    final String subject = f.workflowId ?? f.cloudAutomationId ?? f.connectionId ?? f.automationName ?? '';
    return '${f.kind}|${f.isCloud ? 'cloud' : 'device'}|$subject';
  }

  static String _signatureOf(GuardianFinding f) => '${f.title}\x00${f.body}';

  static int _severityRank(FindingSeverity s) => switch (s) {
        FindingSeverity.critical => 0,
        FindingSeverity.attention => 1,
        FindingSeverity.info => 2,
      };

  /// Critical first, then newest first. The key tiebreak keeps the order
  /// deterministic (List.sort is not stable).
  static List<NotificationEntry> _sorted(Iterable<NotificationEntry> input) {
    final List<NotificationEntry> out = input.toList();
    out.sort((NotificationEntry a, NotificationEntry b) {
      final int severity = _severityRank(a.severity).compareTo(_severityRank(b.severity));
      if (severity != 0) return severity;
      final int time = b.firstSeenAt.compareTo(a.firstSeenAt);
      if (time != 0) return time;
      return a.key.compareTo(b.key);
    });
    return out;
  }

  // ------------------------------------------------------------------ merge

  /// Folds a fresh Guardian pass into the inbox.
  ///
  /// * one row per [keyFor], so a refresh never duplicates a notification
  /// * [NotificationEntry.firstSeenAt] survives refreshes
  /// * read state survives refreshes, unless Guardian's wording changed —
  ///   different wording means new information, so it comes back as unread
  /// * dismissed rows stay gone until their wording changes or they resolve
  NotificationCenter merge(
    Iterable<GuardianFinding> findings, {
    required DateTime now,
  }) {
    final Map<String, NotificationEntry> previous = <String, NotificationEntry>{
      for (final NotificationEntry e in entries) e.key: e,
    };
    final List<NotificationEntry> next = <NotificationEntry>[];
    final Set<String> live = <String>{};

    for (final GuardianFinding f in findings) {
      final String key = keyFor(f);
      if (dismissed[key] == _signatureOf(f)) continue; // dismissed, unchanged
      live.add(key);
      final NotificationEntry? old = previous[key];
      // Read either in this session (previous entry) or a previous one
      // (restored keys), and only still read while Guardian's wording is the
      // same: changed wording is new information, so it comes back unread.
      final bool wasRead = (old?.isRead ?? false) || readKeys.contains(key);
      final bool unchanged = old == null || (old.title == f.title && old.body == f.body);
      next.add(NotificationEntry(
        key: key,
        kind: f.kind,
        severity: f.severity,
        certain: f.certain,
        title: f.title,
        body: f.body,
        why: f.why,
        isCloud: f.isCloud,
        automationName: f.automationName,
        workflowId: f.workflowId,
        cloudAutomationId: f.cloudAutomationId,
        connectionId: f.connectionId,
        actionLabel: f.actionLabel,
        detectedAt: f.detectedAt,
        firstSeenAt: old?.firstSeenAt ?? f.detectedAt ?? now,
        isRead: wasRead && unchanged,
      ));
    }

    // Dismissals for problems that no longer exist are dropped, so the store
    // can't grow without bound. Read state is derived from the entries
    // themselves, which keeps it in step with the "changed wording" rule.
    final Map<String, String> nextDismissed = <String, String>{
      for (final MapEntry<String, String> e in dismissed.entries)
        if (live.contains(e.key)) e.key: e.value,
    };

    return NotificationCenter(
      entries: _sorted(next),
      readKeys: <String>{
        for (final NotificationEntry e in next)
          if (e.isRead) e.key,
      },
      dismissed: nextDismissed,
    );
  }

  // ------------------------------------------------------------------ reads

  int get unreadCount => entries.where((NotificationEntry e) => !e.isRead).length;

  int get criticalCount =>
      entries.where((NotificationEntry e) => e.severity == FindingSeverity.critical).length;

  bool get isEmpty => entries.isEmpty;

  List<NotificationEntry> visible([NotificationFilter filter = NotificationFilter.all]) => filter ==
          NotificationFilter.unread
      ? entries.where((NotificationEntry e) => !e.isRead).toList(growable: false)
      : entries;

  int countFor(NotificationFilter filter) => visible(filter).length;

  NotificationEntry? byKey(String key) {
    for (final NotificationEntry e in entries) {
      if (e.key == key) return e;
    }
    return null;
  }

  NotificationCenter _withEntries(List<NotificationEntry> next) =>
      NotificationCenter(entries: _sorted(next), readKeys: readKeys, dismissed: dismissed);

  NotificationCenter markRead(String key) => _withEntries(<NotificationEntry>[
        for (final NotificationEntry e in entries) e.key == key ? e.copyWith(isRead: true) : e,
      ]).copyWith(readKeys: <String>{...readKeys, key});

  NotificationCenter markAllRead() => NotificationCenter(
        entries: <NotificationEntry>[
          for (final NotificationEntry e in entries) e.copyWith(isRead: true),
        ],
        readKeys: <String>{...readKeys, ...entries.map((NotificationEntry e) => e.key)},
        dismissed: dismissed,
      );

  /// Hides a row until Guardian's wording for it changes, or it resolves.
  NotificationCenter dismiss(String key) {
    final NotificationEntry? target = byKey(key);
    if (target == null) return this;
    return NotificationCenter(
      entries: <NotificationEntry>[
        for (final NotificationEntry e in entries)
          if (e.key != key) e,
      ],
      readKeys: readKeys,
      dismissed: <String, String>{...dismissed, key: target.signature},
    );
  }

  NotificationCenter copyWith({
    List<NotificationEntry>? entries,
    Set<String>? readKeys,
    Map<String, String>? dismissed,
  }) =>
      NotificationCenter(
        entries: entries ?? this.entries,
        readKeys: readKeys ?? this.readKeys,
        dismissed: dismissed ?? this.dismissed,
      );
}
