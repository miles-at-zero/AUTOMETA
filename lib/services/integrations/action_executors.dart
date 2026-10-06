import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../domain/engine/step_context.dart';
import '../../domain/engine/step_executor.dart';
import '../../domain/engine/step_result.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/step.dart';
import '../net/api_client.dart';

/// Local notification block (spec §16, §26).
class NotificationStepExecutor extends StepExecutor {
  NotificationStepExecutor({required this.poster, required this.permissionCheck});

  /// Port to the platform notification service.
  final Future<void> Function({required String title, required String body, String? payload})
      poster;

  /// Whether the user granted `POST_NOTIFICATIONS` (Android 13+).
  final Future<bool> Function() permissionCheck;

  final Logger _log = Logger.withTag(LogTags.notify);

  @override
  StepKind get kind => StepKind.notification;

  @override
  Future<bool> get isAvailable async => permissionCheck();

  @override
  String get availabilityHint => 'Allow notifications in Android settings';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! NotificationStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'notification.bad_step');
    }
    final String title = context.resolve(step.title);
    final String body = context.resolve(step.body);

    if (context.dryRun) {
      return StepResult.simulated(detail: 'Would notify: $title — $body');
    }

    if (!await permissionCheck()) {
      return const StepResult.failed(
        reason: 'Notifications are turned off for AUTOMETA',
        code: 'notification.denied',
      );
    }

    try {
      await poster(title: title, body: body, payload: context.workflow.id);
      return StepResult(
        outcome: StepOutcome.success,
        detail: body.isEmpty ? title : body,
        code: 'notification.shown',
      );
    } catch (error) {
      _log.warn('Notification failed', error);
      return StepResult.failed(
        reason: 'Notification could not be shown: $error',
        code: 'notification.failed',
        retriable: true,
      );
    }
  }
}

/// Generic HTTP block (spec §16).
class HttpStepExecutor extends StepExecutor {
  HttpStepExecutor({required this.apiClient});

  final ApiClient apiClient;
  final Logger _log = Logger.withTag('HTTP');

  @override
  StepKind get kind => StepKind.http;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'Available — needs an internet connection';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! HttpStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'http.bad_step');
    }

    final String url = context.resolve(step.url);
    if (url.isEmpty || !url.startsWith('http')) {
      return const StepResult.failed(reason: 'HTTP block needs a valid URL', code: 'http.url');
    }

    final Map<String, String> headers = context.resolver.resolveMap(step.headers);
    final String body = context.resolve(step.body);

    if (context.dryRun) {
      return StepResult.simulated(
        detail: 'Would ${step.method} $url${body.isEmpty ? '' : ' with a ${body.length}-byte body'}',
      );
    }

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: step.method,
      url: url,
      headers: headers,
      body: body.isEmpty ? null : body,
      timeout: Duration(seconds: step.timeoutSeconds),
    ));

    if (!response.reachedServer) {
      _log.warn('HTTP ${step.method} failed: ${response.transportError}');
      return StepResult.failed(
        reason: response.transportError ?? 'Request did not reach the server',
        code: 'http.transport',
        retriable: true,
      );
    }

    final bool inRange =
        response.statusCode >= step.successStatusMin && response.statusCode <= step.successStatusMax;
    final String summary =
        'HTTP ${response.statusCode}${response.body.isEmpty ? '' : ' · ${_truncate(response.body)}'}';

    final Map<String, String> outputs = <String, String>{
      step.outputVariable: response.body,
      '${step.outputVariable}_status': '${response.statusCode}',
    };

    if (!inRange) {
      return StepResult(
        outcome: StepOutcome.failed,
        detail: 'Expected ${step.successStatusMin}-${step.successStatusMax}, got ${response.statusCode}',
        code: 'http.status',
        retriable: response.statusCode >= 500 || response.statusCode == 429,
        outputVariables: outputs,
      );
    }

    return StepResult(
      outcome: StepOutcome.success,
      detail: summary,
      code: 'http.ok',
      outputVariables: outputs,
    );
  }

  static String _truncate(String value) {
    final String oneLine = value.replaceAll('\n', ' ').trim();
    return oneLine.length <= 120 ? oneLine : '${oneLine.substring(0, 120)}…';
  }
}

/// Outbound webhook block (spec §16). Always POST, always https.
class WebhookStepExecutor extends StepExecutor {
  WebhookStepExecutor({required this.apiClient});

  final ApiClient apiClient;

  @override
  StepKind get kind => StepKind.webhook;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'Available — needs an internet connection';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! WebhookStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'webhook.bad_step');
    }
    final String url = context.resolve(step.url);
    if (!url.startsWith('https://')) {
      return const StepResult.failed(
        reason: 'Webhook URLs must use https://',
        code: 'webhook.insecure',
      );
    }
    final String payload = context.resolve(step.payload);
    if (context.dryRun) {
      return StepResult.simulated(detail: 'Would POST to $url');
    }

    final ApiResponse response = await apiClient.send(ApiRequest(
      method: 'POST',
      url: url,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'User-Agent': '${AppInfo.name}/${AppInfo.version}',
        ...context.resolver.resolveMap(step.headers),
      },
      body: payload,
    ));

    if (!response.reachedServer) {
      return StepResult.failed(
        reason: response.transportError ?? 'Webhook did not reach the server',
        code: 'webhook.transport',
        retriable: true,
      );
    }
    if (!response.isSuccess) {
      return StepResult.failed(
        reason: 'Webhook returned HTTP ${response.statusCode}',
        code: 'webhook.status',
        retriable: response.statusCode >= 500,
      );
    }
    return StepResult(
      outcome: StepOutcome.success,
      detail: 'Delivered (HTTP ${response.statusCode})',
      code: 'webhook.ok',
    );
  }
}

/// Clipboard block.
class ClipboardStepExecutor extends StepExecutor {
  ClipboardStepExecutor({required this.copy});

  final Future<void> Function(String text) copy;

  @override
  StepKind get kind => StepKind.clipboard;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'Available while the app can reach the system clipboard';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! ClipboardStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'clipboard.bad_step');
    }
    final String text = context.resolve(step.text);
    if (context.dryRun) return StepResult.simulated(detail: 'Would copy ${text.length} characters');
    try {
      await copy(text);
      return StepResult(
        outcome: StepOutcome.success,
        detail: 'Copied ${text.length} characters to the clipboard',
        code: 'clipboard.ok',
      );
    } catch (error) {
      return StepResult.failed(
        reason: 'Clipboard is not reachable from the background: $error',
        code: 'clipboard.failed',
      );
    }
  }
}

/// Open-URL block. Android will not let a background service pull the user to
/// another app, so this block reports the truth when it cannot.
class OpenUrlStepExecutor extends StepExecutor {
  OpenUrlStepExecutor({required this.open, required this.canOpen});

  final Future<bool> Function(Uri uri) open;
  final Future<bool> Function(Uri uri) canOpen;

  @override
  StepKind get kind => StepKind.openUrl;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'Only works while AUTOMETA is in the foreground';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! OpenUrlStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'open_url.bad_step');
    }
    final String raw = context.resolve(step.url);
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.isEmpty) {
      return const StepResult.failed(reason: 'That is not a valid URL', code: 'open_url.invalid');
    }
    if (context.dryRun) return StepResult.simulated(detail: 'Would open $raw');

    final bool supported = await canOpen(uri);
    if (!supported) {
      return StepResult.failed(
        reason: 'Nothing on this device can open $raw',
        code: 'open_url.no_handler',
      );
    }
    final bool launched = await open(uri);
    return launched
        ? StepResult(
            outcome: StepOutcome.success,
            detail: 'Opened $raw',
            code: 'open_url.ok',
          )
        : StepResult.failed(
            reason: 'The system refused to open $raw (AUTOMETA may be in the background)',
            code: 'open_url.blocked',
          );
  }
}

/// Sets a variable; kept here so the registry stays complete even though the
/// engine short-circuits it without leaving the isolate.
class SetVariableStepExecutor extends StepExecutor {
  const SetVariableStepExecutor();

  @override
  StepKind get kind => StepKind.setVariable;

  @override
  Future<bool> get isAvailable async => true;

  @override
  String get availabilityHint => 'Always available';

  @override
  Future<StepResult> execute(WorkflowStep step, StepContext context) async {
    if (step is! SetVariableStep) {
      return StepResult.failed(reason: 'Internal error: wrong block type', code: 'variable.bad_step');
    }
    final String value = context.resolve(step.value);
    context.setVariable(step.name, value);
    return StepResult(
      outcome: context.dryRun ? StepOutcome.simulated : StepOutcome.success,
      detail: '${step.name} = $value',
      code: 'variable.set',
    );
  }
}
