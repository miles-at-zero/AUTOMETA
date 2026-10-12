import 'package:flutter/widgets.dart';

import '../domain/notifications/notification_center.dart';
import '../domain/notifications/notification_store.dart';
import '../services/settings/settings_service.dart';
import 'widgets/guardian_panel.dart';

/// One Guardian pass, shared by the whole navigation shell.
///
/// The dock badge, the Control Room panel and the Notification Center all
/// describe the same problems. Running the pass once at the shell and sharing
/// the result keeps them consistent — and means opening a screen never fires a
/// second Cloud round-trip just to show what the shell already knows.
class GuardianInboxController {
  GuardianInboxController();

  /// The last Guardian pass; null until the first one completes.
  GuardianSnapshot? snapshot;

  /// The inbox built from [snapshot] plus the user's persisted read/dismissed
  /// state. Empty (never null) before the first pass.
  NotificationCenter center = const NotificationCenter();

  bool loaded = false;

  /// Runs a pass and folds it into the inbox. [context] is only touched
  /// synchronously, before any await.
  Future<void> load(BuildContext context, SettingsService settings) async {
    final Future<GuardianSnapshot> pending = loadGuardianSnapshot(context);
    final String? read = await settings.repository.get(NotificationStore.readKey);
    final String? dismissed = await settings.repository.get(NotificationStore.dismissedKey);
    final GuardianSnapshot result = await pending;
    snapshot = result;
    center = NotificationStore.restore(read: read, dismissed: dismissed)
        .merge(result.findings, now: DateTime.now());
    loaded = true;
  }

  /// Writes only what the user owns; findings are always re-derived live.
  Future<void> persist(SettingsService settings) async {
    await settings.repository
        .set(NotificationStore.readKey, NotificationStore.encodeRead(center));
    await settings.repository
        .set(NotificationStore.dismissedKey, NotificationStore.encodeDismissed(center));
  }
}

/// Exposes [GuardianInboxController] to everything below the shell.
class GuardianScope extends InheritedWidget {
  const GuardianScope({
    required this.controller,
    required this.onChanged,
    required this.onRefresh,
    required super.child,
    super.key,
  });

  final GuardianInboxController controller;

  /// Applies a user action (read / dismiss), rebuilds and persists it.
  final void Function(NotificationCenter next) onChanged;

  /// Re-runs the Guardian pass (pull-to-refresh, returning from a fix).
  final Future<void> Function() onRefresh;

  GuardianSnapshot? get snapshot => controller.snapshot;
  NotificationCenter get center => controller.center;
  bool get loaded => controller.loaded;

  int get unreadCount => controller.center.unreadCount;

  static GuardianScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GuardianScope>();

  @override
  bool updateShouldNotify(GuardianScope oldWidget) =>
      oldWidget.controller.snapshot != controller.snapshot ||
      oldWidget.controller.center != controller.center ||
      oldWidget.controller.loaded != controller.loaded;
}
