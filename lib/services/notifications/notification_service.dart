import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/execution_status.dart';
import '../scheduler/alarm_platform.dart';

/// Notification channel ids. Android groups and mutes by channel, so each
/// category gets its own (spec §26).
class NotificationChannels {
  const NotificationChannels._();

  static const String completed = 'autometa.completed';
  static const String failed = 'autometa.failed';
  static const String approval = 'autometa.approval';
  static const String upcoming = 'autometa.upcoming';
  static const String connection = 'autometa.connection';

  /// Autometa Cloud alerts (FCM pushes and the in-app alerts poll). The id
  /// matches the server's FCM `android.notification.channel_id`.
  static const String cloudAlerts = 'cloud_alerts';

  /// Raised by a `Notification` block inside a workflow.
  static const String workflow = 'autometa.workflow';
}

/// Per-category on/off switches, stored in the settings table.
@immutable
class NotificationPreferences {
  const NotificationPreferences({
    this.onCompleted = true,
    this.onFailed = true,
    this.onApproval = true,
    this.onUpcoming = false,
    this.onConnectionFailure = true,
    this.upcomingLeadMinutes = 10,
  });

  final bool onCompleted;
  final bool onFailed;
  final bool onApproval;
  final bool onUpcoming;
  final bool onConnectionFailure;
  final int upcomingLeadMinutes;

  NotificationPreferences copyWith({
    bool? onCompleted,
    bool? onFailed,
    bool? onApproval,
    bool? onUpcoming,
    bool? onConnectionFailure,
    int? upcomingLeadMinutes,
  }) =>
      NotificationPreferences(
        onCompleted: onCompleted ?? this.onCompleted,
        onFailed: onFailed ?? this.onFailed,
        onApproval: onApproval ?? this.onApproval,
        onUpcoming: onUpcoming ?? this.onUpcoming,
        onConnectionFailure: onConnectionFailure ?? this.onConnectionFailure,
        upcomingLeadMinutes: upcomingLeadMinutes ?? this.upcomingLeadMinutes,
      );

  Map<String, String> toMap() => <String, String>{
        'notifications.completed': '$onCompleted',
        'notifications.failed': '$onFailed',
        'notifications.approval': '$onApproval',
        'notifications.upcoming': '$onUpcoming',
        'notifications.connection': '$onConnectionFailure',
        'notifications.upcoming_lead': '$upcomingLeadMinutes',
      };

  factory NotificationPreferences.fromMap(Map<String, String> map) => NotificationPreferences(
        onCompleted: map['notifications.completed'] != 'false',
        onFailed: map['notifications.failed'] != 'false',
        onApproval: map['notifications.approval'] != 'false',
        onUpcoming: map['notifications.upcoming'] == 'true',
        onConnectionFailure: map['notifications.connection'] != 'false',
        upcomingLeadMinutes:
            int.tryParse(map['notifications.upcoming_lead'] ?? '') ?? 10,
      );
}

/// Local notifications (spec §26).
///
/// Only notifications the app can genuinely raise are exposed. There is no
/// "message sent" notification for a personal WhatsApp account, because the
/// app cannot know that.
class NotificationService {
  NotificationService({
    required this.platform,
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final AlarmPlatform platform;
  final FlutterLocalNotificationsPlugin _plugin;
  final Logger _log = Logger.withTag(LogTags.notify);

  bool _initialised = false;
  NotificationPreferences preferences = const NotificationPreferences();

  static const AndroidInitializationSettings _androidInit =
      AndroidInitializationSettings('ic_notification');

  Future<void> initialize() async {
    if (_initialised) return;
    try {
      await _plugin.initialize(
        const InitializationSettings(android: _androidInit),
        onDidReceiveNotificationResponse: _onTap,
      );
      await _createChannels();
      _initialised = true;
      _log.info('Notification channels ready');
    } catch (error) {
      _log.warn('Notification plugin could not initialise', error);
    }
  }

  Future<void> _createChannels() async {
    final AndroidFlutterLocalNotificationsPlugin? android =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.completed,
      'Completed automations',
      description: 'Runs that finished successfully',
      importance: Importance.defaultImportance,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.failed,
      'Failed automations',
      description: 'Runs that failed and may need attention',
      importance: Importance.high,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.approval,
      'Approvals',
      description: 'Actions waiting for your approval',
      importance: Importance.high,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.upcoming,
      'Upcoming automations',
      description: 'Heads-up before a scheduled run',
      importance: Importance.low,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.workflow,
      'Automation output',
      description: 'Notifications produced by your workflows',
      importance: Importance.defaultImportance,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.cloudAlerts,
      'Cloud alerts',
      description: 'Autometa Cloud: failed runs and connections that need you',
      importance: Importance.high,
    ));
    await android.createNotificationChannel(const AndroidNotificationChannel(
      NotificationChannels.connection,
      'Connection problems',
      description: 'An integration stopped working',
      importance: Importance.high,
    ));
  }

  void Function(String? payload)? onTap;

  void _onTap(NotificationResponse response) => onTap?.call(response.payload);

  /// Payload of the local notification whose tap launched the app from a
  /// terminated state (cold start), or null.
  Future<String?> launchPayload() async {
    try {
      final NotificationAppLaunchDetails? d = await _plugin.getNotificationAppLaunchDetails();
      return d?.didNotificationLaunchApp == true ? d?.notificationResponse?.payload : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> ensurePermission() async {
    if (await platform.notificationsPermitted) return true;
    return platform.requestNotificationPermission();
  }

  /// Posts the notification that matches an execution's final state.
  Future<void> notifyExecution(ExecutionRecord record) async {
    if (record.dryRun) return;
    switch (record.status) {
      case ExecutionStatus.success:
        if (!preferences.onCompleted) return;
        await show(
          // Notifications from this service are always local runs (Cloud
          // results live in the Cloud inbox), so mark where it ran.
          title: '📱 ${record.workflowName} completed',
          body: _successBody(record),
          channel: NotificationChannels.completed,
          payload: record.workflowId,
        );
      case ExecutionStatus.failed:
        if (!preferences.onFailed) return;
        await show(
          title: '📱 ${record.workflowName} failed',
          body: record.failureReason ?? 'The automation could not complete',
          channel: NotificationChannels.failed,
          payload: record.id,
        );
      case ExecutionStatus.waitingApproval:
        if (!preferences.onApproval) return;
        await show(
          title: '📱 ${record.workflowName}: message ready',
          body: 'Tap to open WhatsApp & send. Nothing goes out until you tap Send.',
          channel: NotificationChannels.approval,
          payload: 'approval:${record.id}',
        );
      case ExecutionStatus.pending:
      case ExecutionStatus.running:
      case ExecutionStatus.cancelled:
      case ExecutionStatus.skipped:
        // Silent by design: a skipped or deferred run is not worth interrupting
        // the user for, and is visible in the activity log.
        return;
    }
  }

  /// Deliberately avoids the word "sent" for a personal-account handoff.
  String _successBody(ExecutionRecord record) {
    for (final StepExecution step in record.stepResults) {
      if (step.code == 'whatsapp.handed_to_user') {
        return 'WhatsApp is open with your message ready — tap Send';
      }
    }
    return 'Completed';
  }

  Future<void> notifyConnectionProblem(String service, String reason) async {
    if (!preferences.onConnectionFailure) return;
    await show(
      title: '$service connection problem',
      body: reason,
      channel: NotificationChannels.connection,
      payload: 'connection:$service',
    );
  }

  Future<void> notifyUpcoming(String workflowName, DateTime at) async {
    if (!preferences.onUpcoming) return;
    await show(
      title: 'Coming up: $workflowName',
      body: 'Scheduled shortly',
      channel: NotificationChannels.upcoming,
      payload: workflowName,
    );
  }

  Future<void> show({
    required String title,
    required String body,
    required String channel,
    String? payload,
    int? id,
  }) async {
    await initialize();
    if (!await platform.notificationsPermitted) {
      _log.info('Notification suppressed: permission not granted');
      return;
    }
    try {
      await _plugin.show(
        id ?? DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            channel,
            _channelName(channel),
            channelShowBadge: true,
            importance: channel == NotificationChannels.upcoming
                ? Importance.low
                : Importance.high,
            priority: channel == NotificationChannels.upcoming
                ? Priority.low
                : Priority.high,
            styleInformation: BigTextStyleInformation(body),
          ),
        ),
        payload: payload,
      );
    } catch (error) {
      _log.warn('Could not post a notification', error);
    }
  }

  Future<void> cancelAll() async {
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // Nothing to do.
    }
  }

  static String _channelName(String channel) => switch (channel) {
        NotificationChannels.completed => 'Completed automations',
        NotificationChannels.cloudAlerts => 'Cloud alerts',
        NotificationChannels.failed => 'Failed automations',
        NotificationChannels.approval => 'Approvals',
        NotificationChannels.upcoming => 'Upcoming automations',
        NotificationChannels.workflow => 'Automation output',
        NotificationChannels.connection => 'Connection problems',
        _ => AppInfo.name,
      };
}
