import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/models/step.dart';
import '../../domain/models/workflow.dart';
import '../../services/ai/nl_workflow_parser.dart';
import '../../services/settings/settings_service.dart';
import '../../services/templates/template_gallery.dart';
import '../widgets/autometa_widgets.dart';
import 'builder_screen.dart';

/// Quick create (spec §13, §35). Parse → preview → explicit activation.
class CreateScreen extends StatefulWidget {
  const CreateScreen({super.key});

  @override
  State<CreateScreen> createState() => _CreateScreenState();
}

class _CreateScreenState extends State<CreateScreen> {
  final TextEditingController _input = TextEditingController();
  bool _busy = false;
  ParsedWorkflow? _parsed;
  String? _error;

  static const List<String> _examples = <String>[
    'Every morning at 7 send Dad a WhatsApp greeting.',
    'Every Sunday remind me to review my projects.',
    'Every weekday at 8 give me a short AI briefing.',
    'Every Sunday at 18:00 generate an AI summary and notify me.',
  ];

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _interpret() async {
    if (_input.text.trim().isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final AppServices services = context.read<AppServices>();
    final SettingsService settings = context.read<SettingsService>();
    try {
      final ParsedWorkflow p = await services.nlParser.parse(
        _input.text,
        defaultRecipient: settings.defaultRecipientName,
        timeZone: settings.timeZone ?? 'UTC',
      );
      setState(() => _parsed = p);
    } catch (e) {
      setState(() => _error = 'Could not interpret that: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPreview(Workflow w) async {
    final bool? created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => BuilderScreen(initial: w, isPreview: true)),
    );
    if (created == true && mounted) {
      setState(() {
        _parsed = null;
        _input.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final SettingsService settings = context.watch<SettingsService>();
    return Scaffold(
      appBar: AppBar(title: const Text('CREATE')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Text('What do you want AUTOMETA to do?', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: AutometaSpacing.md),
              TextField(
                controller: _input,
                minLines: 3,
                maxLines: 5,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(hintText: 'Describe what you want AUTOMETA to do.'),
                onSubmitted: (_) => _interpret(),
              ),
              const SizedBox(height: AutometaSpacing.md),
              PrimaryAction(label: 'Interpret', icon: Icons.auto_awesome, busy: _busy, onPressed: _interpret),
              if (_error != null) Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: AutometaColors.danger)),
              ),
              if (_parsed != null) ...<Widget>[
                const SizedBox(height: AutometaSpacing.xl),
                _Understood(parsed: _parsed!, onEdit: () => _openPreview(_parsed!.workflow), onCancel: () => setState(() => _parsed = null)),
              ],
              const SizedBox(height: AutometaSpacing.xl),
              const SectionLabel('Examples'),
              for (final String e in _examples)
                Padding(
                  padding: const EdgeInsets.only(bottom: AutometaSpacing.sm),
                  child: Panel(
                    padding: const EdgeInsets.all(AutometaSpacing.md),
                    onTap: () => setState(() => _input.text = e),
                    child: Text('"$e"', style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ),
              const SizedBox(height: AutometaSpacing.xl),
              SectionLabel('Templates', trailing: TextButton(
                onPressed: () => _openPreview(Workflow.fromJson(<String, dynamic>{
                  'id': DateTime.now().microsecondsSinceEpoch.toRadixString(36),
                  'name': 'New automation',
                  'enabled': false,
                  'time_zone': settings.timeZone ?? 'UTC',
                  'trigger': <String, dynamic>{'type': 'schedule', 'time': '07:00', 'repeat': 'daily'},
                  'steps': <dynamic>[],
                })),
                child: const Text('Blank builder'),
              )),
              for (final AutomationTemplate t in TemplateGallery.all)
                Padding(
                  padding: const EdgeInsets.only(bottom: AutometaSpacing.sm),
                  child: Panel(
                    onTap: () => _openPreview(t.instantiate(
                      recipient: settings.defaultRecipientName,
                      timeZone: settings.timeZone ?? 'UTC',
                    )),
                    child: Row(children: <Widget>[
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text(t.name, style: Theme.of(context).textTheme.titleSmall),
                          Text(t.blurb, style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                      StatusPill(label: t.category, color: AutometaColors.secondary),
                    ]),
                  ),
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Understood extends StatelessWidget {
  const _Understood({required this.parsed, required this.onEdit, required this.onCancel});
  final ParsedWorkflow parsed;
  final VoidCallback onEdit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final Workflow w = parsed.workflow;
    return Panel(
      glow: AutometaColors.accent,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
        Row(children: <Widget>[
          Text('I understood:', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          StatusPill(label: parsed.engineLabel, color: parsed.usedAi ? AutometaColors.secondary : AutometaColors.neutral),
        ]),
        const SizedBox(height: AutometaSpacing.md),
        LabeledValue(label: 'Name', value: w.name),
        LabeledValue(label: 'Trigger', value: w.trigger.describe()),
        for (final WorkflowStep s in w.steps) ...<Widget>[
          LabeledValue(label: 'Action', value: s.kind.label),
          if (s is WhatsAppStep) ...<Widget>[
            LabeledValue(label: 'Recipient', value: s.recipient),
            LabeledValue(label: 'Message', value: s.message),
          ],
          if (s is NotificationStep) LabeledValue(label: 'Message', value: s.body),
          if (s is AiStep) LabeledValue(label: 'AI task', value: s.prompt),
        ],
        for (final String a in parsed.assumptions)
          Text('• $a', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AutometaSpacing.sm),
        Text('Nothing is active yet. Review it before creating.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: AutometaSpacing.lg),
        PrimaryAction(label: 'Review & create', icon: Icons.check, onPressed: onEdit),
        const SizedBox(height: 8),
        Row(children: <Widget>[
          Expanded(child: OutlinedButton(onPressed: onEdit, child: const Text('Edit'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: onCancel, child: const Text('Cancel'))),
        ]),
      ]),
    );
  }
}
