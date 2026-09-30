import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/autometa_theme.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/engine/engine_ports.dart';
import '../../domain/engine/variable_resolver.dart';
import '../../domain/models/condition.dart';
import '../../domain/models/step.dart';
import '../../domain/models/trigger.dart';
import '../../domain/models/workflow.dart';
import '../../domain/validation/workflow_validator.dart';
import '../../services/settings/settings_service.dart';
import '../../state/app_state.dart';
import '../widgets/autometa_widgets.dart';
import 'dry_run_sheet.dart';

const Uuid _uuid = Uuid();

/// Visual workflow builder (spec §9): TRIGGER ↓ [CONDITION] ↓ [AI] ↓ ACTION.
///
/// Edits an in-memory [Workflow]; nothing is persisted until Save, and the
/// validator runs live so problems are shown before they can fire.
class BuilderScreen extends StatefulWidget {
  const BuilderScreen({this.initial, this.isPreview = false, super.key});

  final Workflow? initial;

  /// True when opened from the natural-language creator: saving is the
  /// explicit activation step (spec §13).
  final bool isPreview;

  @override
  State<BuilderScreen> createState() => _BuilderScreenState();
}

class _BuilderScreenState extends State<BuilderScreen> {
  late Workflow _wf;
  late final TextEditingController _name;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final SettingsService settings = context.read<SettingsService>();
    _wf = widget.initial ??
        Workflow(
          id: _uuid.v4(),
          name: 'New automation',
          timeZone: settings.timeZone ?? 'UTC',
          trigger: const ScheduleTrigger(timeOfDay: '07:00'),
          steps: const <WorkflowStep>[],
          enabled: false,
        );
    _name = TextEditingController(text: _wf.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _update(Workflow w) => setState(() => _wf = w);

  Future<void> _save({required bool enable}) async {
    final ValidationResult v = const WorkflowValidator().validate(_wf.copyWith(name: _name.text));
    if (!v.isValid) {
      showToast(context, v.summary, color: AutometaColors.danger.withValues(alpha: 0.3));
      return;
    }
    setState(() => _saving = true);
    await context.read<AppState>().save(_wf.copyWith(name: _name.text.trim(), enabled: enable));
    if (!mounted) return;
    Navigator.of(context).pop(true);
    showToast(context, enable ? '${_name.text} enabled' : '${_name.text} saved (inactive)');
  }

  Future<void> _test() async {
    final DryRunReport r = await context.read<AppState>().dryRun(_wf.copyWith(name: _name.text));
    if (mounted) await showDryRunSheet(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final ValidationResult validation = const WorkflowValidator().validate(_wf.copyWith(name: _name.text));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isPreview ? 'Review automation' : (widget.initial == null ? 'New automation' : 'Edit automation')),
        actions: <Widget>[
          IconButton(tooltip: 'Test run', icon: const Icon(Icons.science_outlined), onPressed: _test),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              _TriggerBlock(
                trigger: _wf.trigger,
                onChanged: (WorkflowTrigger t) => _update(_wf.copyWith(trigger: t)),
              ),
              StepListEditor(
                steps: _wf.steps,
                onChanged: (List<WorkflowStep> s) => _update(_wf.copyWith(steps: s)),
              ),
              const SizedBox(height: AutometaSpacing.xl),
              _SettingsBlock(workflow: _wf, onChanged: _update),
              const SizedBox(height: AutometaSpacing.lg),
              for (final ValidationIssue i in validation.issues)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(children: <Widget>[
                    Icon(i.isError ? Icons.error_outline : Icons.info_outline,
                        size: 16, color: i.isError ? AutometaColors.danger : AutometaColors.warning),
                    const SizedBox(width: 6),
                    Expanded(child: Text(i.message, style: Theme.of(context).textTheme.bodySmall)),
                  ]),
                ),
              const SizedBox(height: AutometaSpacing.lg),
              PrimaryAction(
                label: widget.isPreview ? 'Create Automation' : 'Save & enable',
                icon: Icons.check,
                busy: _saving,
                onPressed: validation.isValid ? () => _save(enable: true) : null,
              ),
              const SizedBox(height: AutometaSpacing.sm),
              OutlinedButton(
                onPressed: validation.isValid && !_saving ? () => _save(enable: false) : null,
                child: const Text('Save without enabling'),
              ),
              if (widget.isPreview)
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
              const SizedBox(height: AutometaSpacing.xxl),
            ]),
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Trigger
// -----------------------------------------------------------------------------

class _BlockCard extends StatelessWidget {
  const _BlockCard({required this.icon, required this.kicker, required this.title, this.subtitle, this.color, this.onTap, this.trailing});
  final IconData icon;
  final String kicker;
  final String title;
  final String? subtitle;
  final Color? color;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? AutometaColors.accent;
    return Panel(
      onTap: onTap,
      accentLeft: true,
      glow: c,
      padding: const EdgeInsets.fromLTRB(AutometaSpacing.lg, AutometaSpacing.md, AutometaSpacing.sm, AutometaSpacing.md),
      child: Row(children: <Widget>[
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: c, size: 20),
        ),
        const SizedBox(width: AutometaSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(kicker.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c, letterSpacing: 1.4)),
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (subtitle != null && subtitle!.isNotEmpty)
              Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class _TriggerBlock extends StatelessWidget {
  const _TriggerBlock({required this.trigger, required this.onChanged});
  final WorkflowTrigger trigger;
  final ValueChanged<WorkflowTrigger> onChanged;

  @override
  Widget build(BuildContext context) => _BlockCard(
        icon: Icons.schedule,
        kicker: 'Trigger · ${trigger.type.label}',
        title: trigger.describe(),
        onTap: () async {
          final WorkflowTrigger? t = await showModalBottomSheet<WorkflowTrigger>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => TriggerEditor(initial: trigger),
          );
          if (t != null) onChanged(t);
        },
        trailing: const Icon(Icons.chevron_right),
      );
}

class TriggerEditor extends StatefulWidget {
  const TriggerEditor({required this.initial, super.key});
  final WorkflowTrigger initial;

  @override
  State<TriggerEditor> createState() => _TriggerEditorState();
}

class _TriggerEditorState extends State<TriggerEditor> {
  late TriggerType _type = widget.initial.type;
  late ScheduleTrigger _schedule =
      widget.initial is ScheduleTrigger ? widget.initial as ScheduleTrigger : const ScheduleTrigger();
  late DateTimeTrigger _dateTime = widget.initial is DateTimeTrigger
      ? widget.initial as DateTimeTrigger
      : DateTimeTrigger(at: DateTime.now().add(const Duration(hours: 1)));
  late String _event = widget.initial is AppEventTrigger ? (widget.initial as AppEventTrigger).event : 'app_opened';

  WorkflowTrigger _build() => switch (_type) {
        TriggerType.schedule => _schedule,
        TriggerType.dateTime => _dateTime,
        TriggerType.manual => const ManualTrigger(),
        TriggerType.appEvent => AppEventTrigger(event: _event),
        TriggerType.webhook => widget.initial is WebhookTrigger
            ? widget.initial
            : WebhookTrigger(token: _uuid.v4().replaceAll('-', '')),
      };

  Future<void> _pickTime() async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _schedule.hour, minute: _schedule.minute),
    );
    if (t != null) setState(() => _schedule = _schedule.copyWith(timeOfDay: Formatters.minutesTo24(t.hour * 60 + t.minute)));
  }

  Future<void> _pickDateTime() async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _dateTime.at,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
    );
    if (d == null || !mounted) return;
    final TimeOfDay? t = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_dateTime.at));
    if (t == null) return;
    setState(() => _dateTime = _dateTime.copyWith(at: DateTime(d.year, d.month, d.day, t.hour, t.minute)));
  }

  @override
  Widget build(BuildContext context) {
    const List<String> days = <String>['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(AutometaSpacing.xl, 0, AutometaSpacing.xl,
            AutometaSpacing.xl + MediaQuery.viewInsetsOf(context).bottom),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Text('Trigger', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AutometaSpacing.md),
            Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
              for (final TriggerType t in TriggerType.values)
                ChoiceChip(label: Text(t.label), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
            ]),
            const SizedBox(height: AutometaSpacing.lg),
            if (_type == TriggerType.schedule) ...<Widget>[
              DropdownButtonFormField<ScheduleRepeat>(
                value: _schedule.repeat,
                decoration: const InputDecoration(labelText: 'Repeat'),
                items: <DropdownMenuItem<ScheduleRepeat>>[
                  for (final ScheduleRepeat r in ScheduleRepeat.values) DropdownMenuItem<ScheduleRepeat>(value: r, child: Text(r.label)),
                ],
                onChanged: (ScheduleRepeat? r) => setState(() => _schedule = _schedule.copyWith(repeat: r)),
              ),
              const SizedBox(height: AutometaSpacing.md),
              if (_schedule.repeat != ScheduleRepeat.interval)
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.access_time),
                  label: Text(Formatters.humanize24(_schedule.timeOfDay)),
                ),
              if (_schedule.repeat == ScheduleRepeat.days || _schedule.repeat == ScheduleRepeat.weekly) ...<Widget>[
                const SizedBox(height: AutometaSpacing.md),
                Wrap(spacing: 6, children: <Widget>[
                  for (int d = 1; d <= 7; d++)
                    FilterChip(
                      label: Text(days[d - 1]),
                      selected: _schedule.weekdays.contains(d),
                      onSelected: (bool on) {
                        final Set<int> next = _schedule.repeat == ScheduleRepeat.weekly ? <int>{} : <int>{..._schedule.weekdays};
                        on ? next.add(d) : next.remove(d);
                        setState(() => _schedule = _schedule.copyWith(weekdays: next));
                      },
                    ),
                ]),
              ],
              if (_schedule.repeat == ScheduleRepeat.monthly) ...<Widget>[
                const SizedBox(height: AutometaSpacing.md),
                TextFormField(
                  initialValue: '${_schedule.dayOfMonth}',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Day of month (1–31)'),
                  onChanged: (String v) => _schedule = _schedule.copyWith(dayOfMonth: int.tryParse(v) ?? 1),
                ),
              ],
              if (_schedule.repeat == ScheduleRepeat.interval) ...<Widget>[
                TextFormField(
                  initialValue: '${_schedule.intervalMinutes}',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Every N minutes'),
                  onChanged: (String v) => _schedule = _schedule.copyWith(intervalMinutes: int.tryParse(v) ?? 60),
                ),
              ],
            ],
            if (_type == TriggerType.dateTime) ...<Widget>[
              OutlinedButton.icon(
                onPressed: _pickDateTime,
                icon: const Icon(Icons.event),
                label: Text(Formatters.stamp(_dateTime.at)),
              ),
              const SizedBox(height: AutometaSpacing.md),
              Wrap(spacing: 8, children: <Widget>[
                for (final int m in <int>[15, 30, 60, 180])
                  ActionChip(
                    label: Text('In ${Formatters.duration(Duration(minutes: m))}'),
                    onPressed: () => setState(() => _dateTime = DateTimeTrigger.countdown(Duration(minutes: m))),
                  ),
              ]),
              const SizedBox(height: AutometaSpacing.md),
              DropdownButtonFormField<DateTimeRepeat>(
                value: _dateTime.repeat,
                decoration: const InputDecoration(labelText: 'Recurrence'),
                items: <DropdownMenuItem<DateTimeRepeat>>[
                  for (final DateTimeRepeat r in DateTimeRepeat.values) DropdownMenuItem<DateTimeRepeat>(value: r, child: Text(r.label)),
                ],
                onChanged: (DateTimeRepeat? r) => setState(() => _dateTime = _dateTime.copyWith(repeat: r)),
              ),
            ],
            if (_type == TriggerType.manual)
              const Text('Runs only when you press Run now.'),
            if (_type == TriggerType.appEvent)
              DropdownButtonFormField<String>(
                value: _event,
                decoration: const InputDecoration(labelText: 'Event'),
                items: <DropdownMenuItem<String>>[
                  for (final MapEntry<String, String> e in AppEventTrigger.supportedEvents.entries)
                    DropdownMenuItem<String>(value: e.key, child: Text(e.value)),
                ],
                onChanged: (String? v) => setState(() => _event = v ?? _event),
              ),
            if (_type == TriggerType.webhook)
              const Text('A secret token is generated for this workflow. Configure the inbound '
                  'endpoint under Connections → Webhooks. Webhooks only reach the device while '
                  'AUTOMETA can receive them.'),
            const SizedBox(height: AutometaSpacing.xl),
            PrimaryAction(label: 'Done', onPressed: () => Navigator.of(context).pop(_build())),
          ]),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Steps
// -----------------------------------------------------------------------------

/// Recursive list editor, used for the top level and for IF/ELSE branches.
class StepListEditor extends StatelessWidget {
  const StepListEditor({required this.steps, required this.onChanged, this.depth = 0, super.key});

  final List<WorkflowStep> steps;
  final ValueChanged<List<WorkflowStep>> onChanged;
  final int depth;

  Future<void> _add(BuildContext context, int index) async {
    final StepKind? kind = await showModalBottomSheet<StepKind>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(shrinkWrap: true, children: <Widget>[
          for (final StepKind k in StepKind.values)
            if (!(k == StepKind.condition && depth >= EngineLimits.maxConditionDepth - 1))
              ListTile(leading: Icon(stepIcon(k)), title: Text(k.label), subtitle: Text(k.blurb), onTap: () => Navigator.pop(context, k)),
        ]),
      ),
    );
    if (kind == null || !context.mounted) return;
    final WorkflowStep? step = await editStep(context, newStep(kind, context.read<SettingsService>().defaultRecipientName));
    if (step == null) return;
    onChanged(<WorkflowStep>[...steps]..insert(index, step));
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        for (int i = 0; i < steps.length; i++) ...<Widget>[
          const FlowConnector(),
          _StepTile(
            step: steps[i],
            depth: depth,
            onChanged: (WorkflowStep s) => onChanged(<WorkflowStep>[...steps]..[i] = s),
            onDelete: () => onChanged(<WorkflowStep>[...steps]..removeAt(i)),
            onMoveUp: i == 0 ? null : () => onChanged(<WorkflowStep>[...steps]..insert(i - 1, steps[i])..removeAt(i + 1)),
          ),
        ],
        const FlowConnector(),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => _add(context, steps.length),
            icon: const Icon(Icons.add, size: 18),
            label: Text(depth == 0 ? 'Add block' : 'Add to branch'),
          ),
        ),
      ]);
}

class _StepTile extends StatelessWidget {
  const _StepTile({required this.step, required this.depth, required this.onChanged, required this.onDelete, this.onMoveUp});
  final WorkflowStep step;
  final int depth;
  final ValueChanged<WorkflowStep> onChanged;
  final VoidCallback onDelete;
  final VoidCallback? onMoveUp;

  Color get _color => switch (step.kind) {
        StepKind.ai => AutometaColors.secondary,
        StepKind.condition => AutometaColors.warning,
        StepKind.delay => AutometaColors.neutral,
        StepKind.whatsapp => AutometaColors.success,
        _ => AutometaColors.accent,
      };

  @override
  Widget build(BuildContext context) {
    final Widget card = _BlockCard(
      icon: stepIcon(step.kind),
      kicker: step.kind.label,
      title: step.label ?? step.describe(),
      subtitle: _subtitle(step),
      color: _color,
      onTap: () async {
        final WorkflowStep? s = await editStep(context, step);
        if (s != null) onChanged(s);
      },
      trailing: PopupMenuButton<String>(
        onSelected: (String a) {
          if (a == 'delete') onDelete();
          if (a == 'up') onMoveUp?.call();
        },
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          if (onMoveUp != null) const PopupMenuItem<String>(value: 'up', child: Text('Move up')),
          const PopupMenuItem<String>(value: 'delete', child: Text('Remove')),
        ],
      ),
    );
    final WorkflowStep s = step;
    if (s is! ConditionStep) return card;
    final AutometaSemanticColors colors = AutometaSemanticColors.of(context);
    Widget branch(String label, List<WorkflowStep> list, ValueChanged<List<WorkflowStep>> set) => Container(
          margin: const EdgeInsets.only(left: 14, top: 8),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.borderStrong, width: 2))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AutometaColors.warning)),
            StepListEditor(steps: list, depth: depth + 1, onChanged: set),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      card,
      branch('IF TRUE', s.thenSteps, (List<WorkflowStep> l) => onChanged(s.copyWith(thenSteps: l))),
      branch('ELSE', s.elseSteps, (List<WorkflowStep> l) => onChanged(s.copyWith(elseSteps: l))),
    ]);
  }

  static String? _subtitle(WorkflowStep s) => switch (s) {
        WhatsAppStep(:final String message) => message,
        NotificationStep(:final String title) => title,
        AiStep(:final String outputVariable) => '→ {{$outputVariable}}',
        _ => null,
      };
}

/// Default block for a kind.
WorkflowStep newStep(StepKind kind, String recipient) {
  final String id = _uuid.v4();
  return switch (kind) {
    StepKind.whatsapp => WhatsAppStep(id: id, recipient: recipient, message: '{{greeting}} {{name}}'),
    StepKind.notification => NotificationStep(id: id, title: 'AUTOMETA', body: ''),
    StepKind.ai => AiStep(id: id, prompt: 'Generate a short friendly message for {{name}}.', maxLength: 120),
    StepKind.http => HttpStep(id: id, url: 'https://'),
    StepKind.webhook => WebhookStep(id: id, url: 'https://', payload: '{"workflow":"{{workflow}}","time":"{{iso}}"}'),
    StepKind.clipboard => ClipboardStep(id: id, text: '{{ai_output}}'),
    StepKind.openUrl => OpenUrlStep(id: id, url: 'https://'),
    StepKind.condition => ConditionStep(
        id: id,
        condition: const Condition(left: '{{day}}', operator: ConditionOperator.equals, right: 'Sunday'),
      ),
    StepKind.delay => DelayStep(id: id, seconds: 1800),
    StepKind.setVariable => SetVariableStep(id: id, name: 'message', value: ''),
  };
}

/// Opens the editor sheet for one block and returns the edited copy.
Future<WorkflowStep?> editStep(BuildContext context, WorkflowStep step) => showModalBottomSheet<WorkflowStep>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _StepEditor(step: step),
    );

class _StepEditor extends StatefulWidget {
  const _StepEditor({required this.step});
  final WorkflowStep step;

  @override
  State<_StepEditor> createState() => _StepEditorState();
}

class _StepEditorState extends State<_StepEditor> {
  late WorkflowStep _s = widget.step;

  Widget _field(String label, String value, ValueChanged<String> onChanged, {int maxLines = 1, TextInputType? type, String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: AutometaSpacing.md),
        child: TextFormField(
          initialValue: value,
          maxLines: maxLines,
          minLines: 1,
          keyboardType: type,
          decoration: InputDecoration(labelText: label, helperText: helper, helperMaxLines: 3),
          onChanged: onChanged,
        ),
      );

  Widget _variableChips(void Function(String token) insert) => Wrap(spacing: 6, runSpacing: 6, children: <Widget>[
        for (final String v in const <String>['name', 'day', 'date', 'time', 'greeting', 'ai_output', 'message'])
          ActionChip(label: Text('{{$v}}'), onPressed: () => insert('{{$v}}')),
      ]);

  List<Widget> _body() {
    final WorkflowStep s = _s;
    switch (s) {
      case WhatsAppStep():
        return <Widget>[
          DropdownButtonFormField<WhatsAppMode>(
            value: s.mode,
            decoration: const InputDecoration(labelText: 'Action'),
            items: <DropdownMenuItem<WhatsAppMode>>[
              for (final WhatsAppMode m in WhatsAppMode.values) DropdownMenuItem<WhatsAppMode>(value: m, child: Text(m.label)),
            ],
            onChanged: (WhatsAppMode? m) => setState(() => _s = s.copyWith(mode: m)),
          ),
          const SizedBox(height: AutometaSpacing.sm),
          const SizedBox(height: AutometaSpacing.sm),
          DropdownButtonFormField<String>(
            value: s.account ?? 'default',
            decoration: const InputDecoration(labelText: 'Send with'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'default', child: Text('Default account (Connections)')),
              DropdownMenuItem<String>(value: 'personal', child: Text('My WhatsApp (this phone)')),
              DropdownMenuItem<String>(value: 'business', child: Text('WhatsApp Business API')),
            ],
            onChanged: (String? v) => setState(() => _s = v == null || v == 'default'
                ? s.copyWith(clearAccount: true)
                : s.copyWith(account: v)),
          ),
          const SizedBox(height: AutometaSpacing.sm),
          Text(
            s.mode == WhatsAppMode.send
                ? 'Sends automatically with a Business account, or from your phone when auto-send is on '
                    '(Connections → WhatsApp). Otherwise it prepares the message and asks for approval.'
                : 'AUTOMETA opens WhatsApp with the message ready and you tap Send.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AutometaSpacing.md),
          _field('Recipient (contact alias)', s.recipient, (String v) => _s = (_s as WhatsAppStep).copyWith(recipient: v),
              helper: 'Numbers are stored under Settings → Contacts, never in the workflow.'),
          _field('Message', s.message, (String v) => _s = (_s as WhatsAppStep).copyWith(message: v), maxLines: 4),
          _field('Business template name (optional)', s.templateName ?? '',
              (String v) => _s = (_s as WhatsAppStep).copyWith(templateName: v.isEmpty ? null : v)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Always ask before sending'),
            subtitle: const Text('Off = send on schedule without asking (needs auto-send or Business)'),
            value: s.requiresApproval ?? true,
            onChanged: (bool v) => setState(() => _s = s.copyWith(requiresApproval: v)),
          ),
        ];
      case NotificationStep():
        return <Widget>[
          _field('Title', s.title, (String v) => _s = (_s as NotificationStep).copyWith(title: v)),
          _field('Body', s.body, (String v) => _s = (_s as NotificationStep).copyWith(body: v), maxLines: 4),
        ];
      case AiStep():
        return <Widget>[
          DropdownButtonFormField<AiTask>(
            value: s.task,
            decoration: const InputDecoration(labelText: 'AI task'),
            items: <DropdownMenuItem<AiTask>>[
              for (final AiTask t in AiTask.values) DropdownMenuItem<AiTask>(value: t, child: Text(t.label)),
            ],
            onChanged: (AiTask? t) => setState(() => _s = s.copyWith(task: t)),
          ),
          const SizedBox(height: AutometaSpacing.md),
          _field('Instruction', s.prompt, (String v) => _s = (_s as AiStep).copyWith(prompt: v), maxLines: 4),
          _field('Input text (optional)', s.input, (String v) => _s = (_s as AiStep).copyWith(input: v), maxLines: 3),
          _field('Tone', s.tone, (String v) => _s = (_s as AiStep).copyWith(tone: v)),
          _field('Maximum characters', '${s.maxLength}',
              (String v) => _s = (_s as AiStep).copyWith(maxLength: int.tryParse(v) ?? 240), type: TextInputType.number),
          _field('Save result as variable', s.outputVariable, (String v) => _s = (_s as AiStep).copyWith(outputVariable: v),
              helper: 'Use it later as {{${s.outputVariable}}}'),
        ];
      case HttpStep():
        return <Widget>[
          DropdownButtonFormField<String>(
            value: s.method,
            decoration: const InputDecoration(labelText: 'Method'),
            items: <DropdownMenuItem<String>>[
              for (final String m in HttpStep.methods) DropdownMenuItem<String>(value: m, child: Text(m)),
            ],
            onChanged: (String? m) => setState(() => _s = s.copyWith(method: m)),
          ),
          const SizedBox(height: AutometaSpacing.md),
          _field('URL', s.url, (String v) => _s = (_s as HttpStep).copyWith(url: v), type: TextInputType.url),
          _field('Headers (one per line, Key: Value)',
              s.headers.entries.map((MapEntry<String, String> e) => '${e.key}: ${e.value}').join('\n'),
              (String v) => _s = (_s as HttpStep).copyWith(headers: _parseHeaders(v)), maxLines: 3),
          _field('Body', s.body, (String v) => _s = (_s as HttpStep).copyWith(body: v), maxLines: 4),
          Text('Response is saved as {{${s.outputVariable}}} and {{${s.outputVariable}_status}}.',
              style: Theme.of(context).textTheme.bodySmall),
        ];
      case WebhookStep():
        return <Widget>[
          _field('HTTPS URL', s.url, (String v) => _s = (_s as WebhookStep).copyWith(url: v), type: TextInputType.url),
          _field('JSON payload', s.payload, (String v) => _s = (_s as WebhookStep).copyWith(payload: v), maxLines: 5),
        ];
      case ClipboardStep():
        return <Widget>[_field('Text', s.text, (String v) => _s = (_s as ClipboardStep).copyWith(text: v), maxLines: 4)];
      case OpenUrlStep():
        return <Widget>[
          _field('URL', s.url, (String v) => _s = (_s as OpenUrlStep).copyWith(url: v), type: TextInputType.url,
              helper: 'Android only lets an app open links while it is in the foreground.'),
        ];
      case ConditionStep():
        return <Widget>[
          _field('Left value', s.condition.left,
              (String v) => _s = (_s as ConditionStep).copyWith(condition: (_s as ConditionStep).condition.copyWith(left: v))),
          DropdownButtonFormField<ConditionOperator>(
            value: s.condition.operator,
            decoration: const InputDecoration(labelText: 'Operator'),
            isExpanded: true,
            items: <DropdownMenuItem<ConditionOperator>>[
              for (final ConditionOperator o in ConditionOperator.values)
                DropdownMenuItem<ConditionOperator>(value: o, child: Text(o.label)),
            ],
            onChanged: (ConditionOperator? o) => setState(() => _s = s.copyWith(condition: s.condition.copyWith(operator: o))),
          ),
          const SizedBox(height: AutometaSpacing.md),
          if (!s.condition.operator.isUnary)
            _field('Right value', s.condition.right,
                (String v) => _s = (_s as ConditionStep).copyWith(condition: (_s as ConditionStep).condition.copyWith(right: v))),
          Text('Add blocks to the IF and ELSE branches from the builder.', style: Theme.of(context).textTheme.bodySmall),
        ];
      case DelayStep():
        return <Widget>[
          _field('Wait (minutes)', '${(s.seconds / 60).round()}',
              (String v) => _s = (_s as DelayStep).copyWith(seconds: ((int.tryParse(v) ?? 30) * 60)),
              type: TextInputType.number,
              helper: 'Maximum ${EngineLimits.maxDelayStep.inHours} hours. Long waits are handed to the Android '
                  'scheduler and may run a little late under Doze.'),
        ];
      case SetVariableStep():
        return <Widget>[
          _field('Variable name', s.name, (String v) => _s = (_s as SetVariableStep).copyWith(name: v)),
          _field('Value', s.value, (String v) => _s = (_s as SetVariableStep).copyWith(value: v), maxLines: 3),
        ];
    }
  }

  static Map<String, String> _parseHeaders(String raw) {
    final Map<String, String> out = <String, String>{};
    for (final String line in raw.split('\n')) {
      final int i = line.indexOf(':');
      if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              AutometaSpacing.xl, 0, AutometaSpacing.xl, AutometaSpacing.xl + MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Row(children: <Widget>[
                Icon(stepIcon(_s.kind), color: AutometaColors.accent),
                const SizedBox(width: 8),
                Text(_s.kind.label, style: Theme.of(context).textTheme.headlineSmall),
              ]),
              const SizedBox(height: AutometaSpacing.lg),
              ..._body(),
              const SizedBox(height: AutometaSpacing.sm),
              Text('Variables', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 6),
              _variableChips((String token) {
                // Copy to clipboard is the least surprising cross-field behaviour.
                showToast(context, '$token — type or paste it into any field');
              }),
              Text('Built-ins: ${VariableResolver.builtInNames.take(8).join(', ')}…',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: AutometaSpacing.xl),
              PrimaryAction(label: 'Done', onPressed: () => Navigator.of(context).pop(_s)),
            ]),
          ),
        ),
      );
}

// -----------------------------------------------------------------------------
// Workflow-level settings
// -----------------------------------------------------------------------------

class _SettingsBlock extends StatelessWidget {
  const _SettingsBlock({required this.workflow, required this.onChanged});
  final Workflow workflow;
  final ValueChanged<Workflow> onChanged;

  @override
  Widget build(BuildContext context) => Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          const SectionLabel('Run settings'),
          Row(children: <Widget>[
            const Expanded(child: Text('Retries on failure')),
            IconButton(
              onPressed: workflow.maxRetries > 0 ? () => onChanged(workflow.copyWith(maxRetries: workflow.maxRetries - 1)) : null,
              icon: const Icon(Icons.remove),
            ),
            Text('${workflow.maxRetries}'),
            IconButton(
              onPressed: workflow.maxRetries < EngineLimits.maxRetries
                  ? () => onChanged(workflow.copyWith(maxRetries: workflow.maxRetries + 1))
                  : null,
              icon: const Icon(Icons.add),
            ),
          ]),
          Text('Time zone: ${workflow.timeZone}', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AutometaSpacing.md),
          const Text('Custom variables'),
          for (final MapEntry<String, String> e in workflow.variables.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('{{${e.key}}}'),
              subtitle: Text(e.value),
              trailing: IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: () => onChanged(workflow.copyWith(variables: <String, String>{...workflow.variables}..remove(e.key))),
              ),
            ),
          TextButton.icon(
            onPressed: () async {
              final TextEditingController k = TextEditingController();
              final TextEditingController v = TextEditingController();
              final bool? ok = await showDialog<bool>(
                context: context,
                builder: (BuildContext c) => AlertDialog(
                  title: const Text('Add variable'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                    TextField(controller: k, decoration: const InputDecoration(labelText: 'Name')),
                    const SizedBox(height: 8),
                    TextField(controller: v, decoration: const InputDecoration(labelText: 'Value')),
                  ]),
                  actions: <Widget>[
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Add')),
                  ],
                ),
              );
              if (ok == true && k.text.trim().isNotEmpty) {
                onChanged(workflow.copyWith(variables: <String, String>{...workflow.variables, k.text.trim(): v.text}));
              }
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add variable'),
          ),
        ]),
      );
}
