import 'package:flutter/foundation.dart';

/// How the user left the first-run flow.
enum OnboardingOutcome {
  /// Never finished or skipped: the first-run flow is shown.
  none('none'),

  /// Finished by choosing a starting path.
  completed('completed'),

  /// Left via "Skip setup". Never forced again.
  skipped('skipped');

  const OnboardingOutcome(this.wire);
  final String wire;

  static OnboardingOutcome fromWire(String? v) =>
      OnboardingOutcome.values.firstWhere((OnboardingOutcome o) => o.wire == v, orElse: () => OnboardingOutcome.none);
}

/// Versioned first-run state, stored in the device settings table. It is
/// independent of Autometa Cloud sign-in: onboarding introduces the product,
/// and the Cloud account is optional (Connections → Cloud connections).
///
/// [version] records which flow the user saw. A future flow can bump
/// [currentVersion] and use [sawOlderFlow] to offer a short "what's new"
/// without forcing returning users through first-run again.
@immutable
class OnboardingState {
  const OnboardingState({this.version = 0, this.outcome = OnboardingOutcome.none});

  /// v1 = the original Dad-reminder flow; v2 = general first-run flow.
  static const int currentVersion = 2;

  static const String versionKey = 'onboarding.version';
  static const String outcomeKey = 'onboarding.outcome';

  /// Pre-versioning flag written by the v1 flow (kept for migration).
  static const String legacyCompleteKey = 'onboarding.complete';

  final int version;
  final OnboardingOutcome outcome;

  /// Show the first-run flow only to people who never finished or skipped it.
  bool get shouldShow => outcome == OnboardingOutcome.none;

  bool get sawOlderFlow => outcome != OnboardingOutcome.none && version < currentVersion;

  /// Reads stored settings. A v1 user (only `onboarding.complete=true`) is
  /// treated as having completed version 1, so it is not shown again.
  factory OnboardingState.fromSettings(Map<String, String> all) {
    final OnboardingOutcome stored = OnboardingOutcome.fromWire(all[outcomeKey]);
    final int version = int.tryParse(all[versionKey] ?? '') ?? 0;
    if (stored == OnboardingOutcome.none && all[legacyCompleteKey] == 'true') {
      return const OnboardingState(version: 1, outcome: OnboardingOutcome.completed);
    }
    return OnboardingState(version: version, outcome: stored);
  }

  Map<String, String> toSettings() => <String, String>{
        versionKey: '$version',
        outcomeKey: outcome.wire,
        // Keep the legacy flag in sync for older builds after a downgrade.
        legacyCompleteKey: shouldShow ? 'false' : 'true',
      };
}

/// Where the user wanted to go when they left onboarding. Held in memory and
/// consumed once by the app shell, which opens the real screen (create flow,
/// template preview in the real builder, Connections). Never persisted, so a
/// restart can't replay it.
@immutable
class OnboardingIntent {
  const OnboardingIntent._(this.kind, [this.templateId]);

  const OnboardingIntent.explore() : this._(OnboardingIntentKind.explore);
  const OnboardingIntent.createAutomation() : this._(OnboardingIntentKind.createAutomation);
  const OnboardingIntent.connectApp() : this._(OnboardingIntentKind.connectApp);
  /// Drafts were created (e.g. Dad reminders): open the Automations list.
  const OnboardingIntent.reviewAutomations() : this._(OnboardingIntentKind.reviewAutomations);
  const OnboardingIntent.template(String id) : this._(OnboardingIntentKind.template, id);

  final OnboardingIntentKind kind;
  final String? templateId;

  @override
  bool operator ==(Object other) => other is OnboardingIntent && other.kind == kind && other.templateId == templateId;

  @override
  int get hashCode => Object.hash(kind, templateId);
}

enum OnboardingIntentKind { explore, createAutomation, connectApp, template, reviewAutomations }
