import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/json_utils.dart';
import 'condition.dart';

/// Catalogue of every block the builder can insert (spec §9, §16).
enum StepKind {
  whatsapp('whatsapp', 'WhatsApp', 'Personal WhatsApp (prepare, you tap Send) or WhatsApp Business (official API)'),
  notification('notification', 'Notification', 'Show a local Android notification'),
  ai('ai', 'AI', 'Generate, rewrite, summarize, classify or extract'),
  http('http', 'HTTP request', 'Call any REST endpoint'),
  webhook('webhook', 'Webhook', 'POST a payload to an external service'),
  clipboard('clipboard', 'Clipboard', 'Copy text to the clipboard'),
  openUrl('open_url', 'Open URL', 'Open a website or app link'),
  condition('condition', 'Condition', 'Branch with IF / ELSE'),
  delay('delay', 'Wait', 'Pause the run before continuing'),
  setVariable('set_variable', 'Set variable', 'Store a value for later blocks'),
  gmailSend('gmail_send', 'Gmail: send email', 'Send an email from your connected Gmail (Cloud)');

  const StepKind(this.wire, this.label, this.blurb);

  final String wire;
  final String label;
  final String blurb;

  static StepKind fromWire(Object? value, {StepKind fallback = notification}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final StepKind kind in StepKind.values) {
      if (kind.wire == raw || kind.name.toLowerCase() == raw) return kind;
    }
    return fallback;
  }

  /// Blocks that change the shape of the run rather than performing an action.
  bool get isControl => this == condition || this == delay || this == setVariable;

  /// Blocks that need an explicit user approval by default (spec §23).
  bool get requiresApprovalByDefault => this == whatsapp || this == webhook;
}

/// How a WhatsApp step interacts with the platform.
enum WhatsAppMode {
  /// Build the message and stop for approval / user tap-to-send.
  prepare('prepare', 'Personal WhatsApp: prepare (you tap Send)'),

  /// Deliver through an integration that can actually send (Business API only).
  send('send', 'WhatsApp Business: send automatically (official API)'),

  /// Open the conversation in WhatsApp with the text prefilled.
  open('open', 'Personal WhatsApp: open chat');

  const WhatsAppMode(this.wire, this.label);

  final String wire;
  final String label;

  static WhatsAppMode fromWire(Object? value, {WhatsAppMode fallback = prepare}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final WhatsAppMode mode in WhatsAppMode.values) {
      if (mode.wire == raw || mode.name.toLowerCase() == raw) return mode;
    }
    return fallback;
  }
}

/// What the AI block is asked to do (spec §12).
enum AiTask {
  generate('generate', 'Generate text'),
  rewrite('rewrite', 'Rewrite'),
  summarize('summarize', 'Summarize'),
  classify('classify', 'Classify'),
  extract('extract', 'Extract information'),
  convert('convert', 'Convert text'),
  structured('structured', 'Generate structured data');

  const AiTask(this.wire, this.label);

  final String wire;
  final String label;

  static AiTask fromWire(Object? value, {AiTask fallback = generate}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final AiTask task in AiTask.values) {
      if (task.wire == raw || task.name.toLowerCase() == raw) return task;
    }
    return fallback;
  }
}

/// One block inside a workflow.
///
/// Steps are immutable value objects; the builder produces a new list on every
/// edit so undo/redo and dirty-checking are trivial.
@immutable
sealed class WorkflowStep {
  const WorkflowStep({required this.id, this.label, this.continueOnError = false});

  final String id;
  final String? label;

  /// When true a failed step is logged but the run continues.
  final bool continueOnError;

  StepKind get kind;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': kind.wire,
        if (label != null && label!.isNotEmpty) 'label': label,
        if (continueOnError) 'continue_on_error': true,
        ...configJson(),
      };

  /// Subclass-specific fields, merged into the top-level JSON object so a
  /// stored workflow reads exactly like the example in spec §36.
  Map<String, dynamic> configJson();

  /// One-line preview for the builder card.
  String describe();

  /// Deep copy used by the editor.
  WorkflowStep copyWithId(String newId);

  static WorkflowStep fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    final StepKind kind = StepKind.fromWire(map['type']);
    return switch (kind) {
      StepKind.whatsapp => WhatsAppStep.fromJson(map),
      StepKind.notification => NotificationStep.fromJson(map),
      StepKind.ai => AiStep.fromJson(map),
      StepKind.http => HttpStep.fromJson(map),
      StepKind.webhook => WebhookStep.fromJson(map),
      StepKind.clipboard => ClipboardStep.fromJson(map),
      StepKind.openUrl => OpenUrlStep.fromJson(map),
      StepKind.condition => ConditionStep.fromJson(map),
      StepKind.delay => DelayStep.fromJson(map),
      StepKind.setVariable => SetVariableStep.fromJson(map),
      StepKind.gmailSend => GmailSendStep.fromJson(map),
    };
  }

  static List<WorkflowStep> listFromJson(Object? json) =>
      asList(json).map(WorkflowStep.fromJson).toList(growable: false);
}

@immutable
class WhatsAppStep extends WorkflowStep {
  const WhatsAppStep({
    required super.id,
    this.mode = WhatsAppMode.prepare,
    this.recipient = 'Dad',
    this.message = '',
    this.templateName,
    this.requiresApproval,
    this.account,
    super.label,
    super.continueOnError,
  });

  final WhatsAppMode mode;

  /// Which WhatsApp account sends this step: 'personal', 'business', or null
  /// for the default chosen in Connections.
  final String? account;

  /// A contact alias ("Dad"), never a raw number in the definition.
  final String recipient;
  final String message;

  /// Approved template name, required by the Business API for business-initiated
  /// conversations.
  final String? templateName;

  /// `null` means "use the integration default": a personal account always
  /// needs approval, a connected Business account does not.
  final bool? requiresApproval;

  @override
  StepKind get kind => StepKind.whatsapp;

  WhatsAppStep copyWith({
    WhatsAppMode? mode,
    String? recipient,
    String? message,
    String? templateName,
    bool? requiresApproval,
    String? account,
    bool clearAccount = false,
    String? label,
    bool? continueOnError,
  }) =>
      WhatsAppStep(
        account: clearAccount ? null : (account ?? this.account),
        id: id,
        mode: mode ?? this.mode,
        recipient: recipient ?? this.recipient,
        message: message ?? this.message,
        templateName: templateName ?? this.templateName,
        requiresApproval: requiresApproval ?? this.requiresApproval,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => WhatsAppStep(
        id: newId,
        account: account,
        mode: mode,
        recipient: recipient,
        message: message,
        templateName: templateName,
        requiresApproval: requiresApproval,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => '${mode.label} → $recipient';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{
        'mode': mode.wire,
        'recipient': recipient,
        'message': message,
        if (templateName != null) 'template': templateName,
        if (requiresApproval != null) 'requires_approval': requiresApproval,
        if (account != null) 'account': account,
      };

  factory WhatsAppStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return WhatsAppStep(
      id: asString(map['id']),
      mode: WhatsAppMode.fromWire(map['mode']),
      recipient: asString(map['recipient'], fallback: 'Dad'),
      message: asString(map['message']),
      templateName: asStringOrNull(map['template']),
      account: asStringOrNull(map['account']),
      requiresApproval: map['requires_approval'] == null
          ? null
          : asBool(map['requires_approval']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class NotificationStep extends WorkflowStep {
  const NotificationStep({
    required super.id,
    this.title = 'AUTOMETA',
    this.body = '',
    super.label,
    super.continueOnError,
  });

  final String title;
  final String body;

  @override
  StepKind get kind => StepKind.notification;

  NotificationStep copyWith({String? title, String? body, String? label, bool? continueOnError}) =>
      NotificationStep(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => NotificationStep(
        id: newId,
        title: title,
        body: body,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => Formatters.preview(body.isEmpty ? title : body, max: 48);

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'title': title, 'body': body};

  factory NotificationStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return NotificationStep(
      id: asString(map['id']),
      title: asString(map['title'], fallback: 'AUTOMETA'),
      body: asString(map['body']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class AiStep extends WorkflowStep {
  const AiStep({
    required super.id,
    this.task = AiTask.generate,
    this.prompt = '',
    this.input = '',
    this.tone = 'Warm',
    this.maxLength = 240,
    this.outputVariable = 'ai_output',
    super.label,
    super.continueOnError,
  });

  final AiTask task;

  /// The instruction given to the model.
  final String prompt;

  /// Optional source text (for rewrite / summarize / classify / extract).
  final String input;
  final String tone;
  final int maxLength;

  /// Variable the result is written to, usable by later blocks.
  final String outputVariable;

  @override
  StepKind get kind => StepKind.ai;

  AiStep copyWith({
    AiTask? task,
    String? prompt,
    String? input,
    String? tone,
    int? maxLength,
    String? outputVariable,
    String? label,
    bool? continueOnError,
  }) =>
      AiStep(
        id: id,
        task: task ?? this.task,
        prompt: prompt ?? this.prompt,
        input: input ?? this.input,
        tone: tone ?? this.tone,
        maxLength: maxLength ?? this.maxLength,
        outputVariable: outputVariable ?? this.outputVariable,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => AiStep(
        id: newId,
        task: task,
        prompt: prompt,
        input: input,
        tone: tone,
        maxLength: maxLength,
        outputVariable: outputVariable,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => '${task.label} · ${Formatters.preview(prompt, max: 40)}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{
        'task': task.wire,
        'prompt': prompt,
        'input': input,
        'tone': tone,
        'max_length': maxLength,
        'output_variable': outputVariable,
      };

  factory AiStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return AiStep(
      id: asString(map['id']),
      task: AiTask.fromWire(map['task']),
      prompt: asString(map['prompt']),
      input: asString(map['input']),
      tone: asString(map['tone'], fallback: 'Warm'),
      maxLength: asInt(map['max_length'], fallback: 240).clamp(20, 4000),
      outputVariable: asString(map['output_variable'], fallback: 'ai_output'),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class HttpStep extends WorkflowStep {
  const HttpStep({
    required super.id,
    this.method = 'GET',
    this.url = '',
    this.headers = const <String, String>{},
    this.body = '',
    this.timeoutSeconds = 30,
    this.successStatusMin = 200,
    this.successStatusMax = 299,
    this.outputVariable = 'http_response',
    super.label,
    super.continueOnError,
  });

  static const List<String> methods = <String>['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];

  final String method;
  final String url;
  final Map<String, String> headers;
  final String body;
  final int timeoutSeconds;
  final int successStatusMin;
  final int successStatusMax;
  final String outputVariable;

  @override
  StepKind get kind => StepKind.http;

  HttpStep copyWith({
    String? method,
    String? url,
    Map<String, String>? headers,
    String? body,
    int? timeoutSeconds,
    String? label,
    bool? continueOnError,
  }) =>
      HttpStep(
        id: id,
        method: method ?? this.method,
        url: url ?? this.url,
        headers: headers ?? this.headers,
        body: body ?? this.body,
        timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
        successStatusMin: successStatusMin,
        successStatusMax: successStatusMax,
        outputVariable: outputVariable,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => HttpStep(
        id: newId,
        method: method,
        url: url,
        headers: headers,
        body: body,
        timeoutSeconds: timeoutSeconds,
        successStatusMin: successStatusMin,
        successStatusMax: successStatusMax,
        outputVariable: outputVariable,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => '$method ${Formatters.preview(url, max: 40)}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{
        'method': method.toUpperCase(),
        'url': url,
        'headers': headers,
        'body': body,
        'timeout_seconds': timeoutSeconds,
        'success_status_min': successStatusMin,
        'success_status_max': successStatusMax,
        'output_variable': outputVariable,
      };

  factory HttpStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return HttpStep(
      id: asString(map['id']),
      method: asString(map['method'], fallback: 'GET').toUpperCase(),
      url: asString(map['url']),
      headers: asStringMap(map['headers']),
      body: asString(map['body']),
      timeoutSeconds: asInt(map['timeout_seconds'], fallback: 30).clamp(1, 300),
      successStatusMin: asInt(map['success_status_min'], fallback: 200),
      successStatusMax: asInt(map['success_status_max'], fallback: 299),
      outputVariable: asString(map['output_variable'], fallback: 'http_response'),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class WebhookStep extends WorkflowStep {
  const WebhookStep({
    required super.id,
    this.url = '',
    this.payload = '',
    this.headers = const <String, String>{},
    super.label,
    super.continueOnError,
  });

  final String url;

  /// JSON payload body; `{{variables}}` are expanded before sending.
  final String payload;
  final Map<String, String> headers;

  @override
  StepKind get kind => StepKind.webhook;

  WebhookStep copyWith({
    String? url,
    String? payload,
    Map<String, String>? headers,
    String? label,
    bool? continueOnError,
  }) =>
      WebhookStep(
        id: id,
        url: url ?? this.url,
        payload: payload ?? this.payload,
        headers: headers ?? this.headers,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => WebhookStep(
        id: newId,
        url: url,
        payload: payload,
        headers: headers,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => 'POST ${Formatters.preview(url, max: 40)}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{
        'url': url,
        'payload': payload,
        'headers': headers,
      };

  factory WebhookStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return WebhookStep(
      id: asString(map['id']),
      url: asString(map['url']),
      payload: asString(map['payload']),
      headers: asStringMap(map['headers']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class ClipboardStep extends WorkflowStep {
  const ClipboardStep({required super.id, this.text = '', super.label, super.continueOnError});

  final String text;

  @override
  StepKind get kind => StepKind.clipboard;

  ClipboardStep copyWith({String? text, String? label, bool? continueOnError}) => ClipboardStep(
        id: id,
        text: text ?? this.text,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => ClipboardStep(
        id: newId,
        text: text,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => Formatters.preview(text, max: 48);

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'text': text};

  factory ClipboardStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return ClipboardStep(
      id: asString(map['id']),
      text: asString(map['text']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class OpenUrlStep extends WorkflowStep {
  const OpenUrlStep({required super.id, this.url = '', super.label, super.continueOnError});

  final String url;

  @override
  StepKind get kind => StepKind.openUrl;

  OpenUrlStep copyWith({String? url, String? label, bool? continueOnError}) => OpenUrlStep(
        id: id,
        url: url ?? this.url,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => OpenUrlStep(
        id: newId,
        url: url,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => Formatters.preview(url, max: 48);

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'url': url};

  factory OpenUrlStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return OpenUrlStep(
      id: asString(map['id']),
      url: asString(map['url']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

/// `IF / ELSE` branching (spec §11). Branches hold full step lists, so a
/// workflow can nest branches up to [EngineLimits.maxConditionDepth].
@immutable
class ConditionStep extends WorkflowStep {
  const ConditionStep({
    required super.id,
    required this.condition,
    this.more = const <Condition>[],
    this.matchAny = false,
    this.thenSteps = const <WorkflowStep>[],
    this.elseSteps = const <WorkflowStep>[],
    super.label,
    super.continueOnError,
  });

  final Condition condition;

  /// Extra rules combined with [condition]: all must pass (AND), or any one
  /// (OR) when [matchAny] is set. Empty for older single-rule blocks.
  final List<Condition> more;
  final bool matchAny;
  final List<WorkflowStep> thenSteps;
  final List<WorkflowStep> elseSteps;

  /// Every rule in order, [condition] first.
  List<Condition> get conditions => <Condition>[condition, ...more];

  @override
  StepKind get kind => StepKind.condition;

  ConditionStep copyWith({
    Condition? condition,
    List<Condition>? more,
    bool? matchAny,
    List<WorkflowStep>? thenSteps,
    List<WorkflowStep>? elseSteps,
    String? label,
    bool? continueOnError,
  }) =>
      ConditionStep(
        id: id,
        condition: condition ?? this.condition,
        more: more ?? this.more,
        matchAny: matchAny ?? this.matchAny,
        thenSteps: thenSteps ?? this.thenSteps,
        elseSteps: elseSteps ?? this.elseSteps,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => ConditionStep(
        id: newId,
        condition: condition,
        more: more,
        matchAny: matchAny,
        thenSteps: thenSteps,
        elseSteps: elseSteps,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => 'IF ${conditions.map((Condition c) => c.describe()).join(matchAny ? ' OR ' : ' AND ')}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{
        'if': condition.toJson(),
        if (more.isNotEmpty) 'more': more.map((Condition c) => c.toJson()).toList(),
        if (more.isNotEmpty) 'match': matchAny ? 'any' : 'all',
        'then': thenSteps.map((WorkflowStep s) => s.toJson()).toList(),
        'else': elseSteps.map((WorkflowStep s) => s.toJson()).toList(),
      };

  factory ConditionStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return ConditionStep(
      id: asString(map['id']),
      condition: Condition.fromJson(map['if']),
      more: asList(map['more']).map(Condition.fromJson).toList(growable: false),
      matchAny: asString(map['match']) == 'any',
      thenSteps: WorkflowStep.listFromJson(map['then']),
      elseSteps: WorkflowStep.listFromJson(map['else']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

/// `WAIT` block (spec §15). Capped at [EngineLimits.maxDelayStep].
@immutable
class DelayStep extends WorkflowStep {
  const DelayStep({required super.id, this.seconds = 1800, super.label, super.continueOnError});

  final int seconds;

  int get effectiveSeconds => seconds.clamp(1, EngineLimits.maxDelayStep.inSeconds);

  DelayStep copyWith({int? seconds, String? label, bool? continueOnError}) => DelayStep(
        id: id,
        seconds: seconds ?? this.seconds,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  StepKind get kind => StepKind.delay;

  @override
  WorkflowStep copyWithId(String newId) => DelayStep(
        id: newId,
        seconds: seconds,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => 'Wait ${Formatters.duration(Duration(seconds: effectiveSeconds))}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'seconds': effectiveSeconds};

  factory DelayStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return DelayStep(
      id: asString(map['id']),
      seconds: asInt(map['seconds'], fallback: 1800).clamp(1, EngineLimits.maxDelayStep.inSeconds),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

@immutable
class SetVariableStep extends WorkflowStep {
  const SetVariableStep({
    required super.id,
    this.name = 'value',
    this.value = '',
    super.label,
    super.continueOnError,
  });

  final String name;
  final String value;

  @override
  StepKind get kind => StepKind.setVariable;

  SetVariableStep copyWith({String? name, String? value, String? label, bool? continueOnError}) =>
      SetVariableStep(
        id: id,
        name: name ?? this.name,
        value: value ?? this.value,
        label: label ?? this.label,
        continueOnError: continueOnError ?? this.continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) => SetVariableStep(
        id: newId,
        name: name,
        value: value,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  String describe() => '$name = ${Formatters.preview(value, max: 32)}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'name': name, 'value': value};

  factory SetVariableStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return SetVariableStep(
      id: asString(map['id']),
      name: asString(map['name'], fallback: 'value'),
      value: asString(map['value']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}

/// Sends an email through the user's Gmail account connected to Autometa
/// Cloud (official Gmail API, OAuth). Cloud-only: the phone never holds
/// Google tokens.
@immutable
class GmailSendStep extends WorkflowStep {
  const GmailSendStep({
    required super.id,
    this.to = '',
    this.subject = '',
    this.body = '',
    super.label,
    super.continueOnError,
  });

  final String to;
  final String subject;
  final String body;

  @override
  StepKind get kind => StepKind.gmailSend;

  GmailSendStep copyWith({String? to, String? subject, String? body}) => GmailSendStep(
        id: id,
        to: to ?? this.to,
        subject: subject ?? this.subject,
        body: body ?? this.body,
        label: label,
        continueOnError: continueOnError,
      );

  @override
  WorkflowStep copyWithId(String newId) =>
      GmailSendStep(id: newId, to: to, subject: subject, body: body, label: label, continueOnError: continueOnError);

  @override
  String describe() => 'Email ${to.isEmpty ? '…' : to}: ${Formatters.preview(subject, max: 32)}';

  @override
  Map<String, dynamic> configJson() => <String, dynamic>{'to': to, 'subject': subject, 'body': body};

  factory GmailSendStep.fromJson(Object? json) {
    final Map<String, dynamic> map = asMap(json);
    return GmailSendStep(
      id: asString(map['id']),
      to: asString(map['to']),
      subject: asString(map['subject']),
      body: asString(map['body']),
      label: asStringOrNull(map['label']),
      continueOnError: asBool(map['continue_on_error']),
    );
  }
}
