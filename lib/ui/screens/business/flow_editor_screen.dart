import 'package:flutter/material.dart';

import '../../../business/business_api.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';
import 'flows_screen.dart';

/// Step catalogue shown in the editor. `feature` mirrors server/src/plans.js
/// so locked steps are labelled; the server is still the source of truth.
class StepKind {
  const StepKind(this.type, this.label, this.icon, this.help, this.feature, [this.preset]);

  final String type;
  final String label;
  final IconData icon;
  final String help;
  final String feature;
  final Json Function()? preset;
}

final List<StepKind> stepKinds = <StepKind>[
  const StepKind('message', 'Send message', Icons.chat_bubble_outline, 'Send a text. Use {{name}} or saved answers like {{item}}.', 'autoReplies'),
  const StepKind('question', 'Ask a question', Icons.help_outline, 'Wait for the customer\'s answer and save it.', 'customerCapture'),
  const StepKind('condition', 'If / else', Icons.call_split, 'Go to different steps depending on answers or tags.', 'autoReplies'),
  StepKind('condition', 'Business hours check', Icons.schedule, 'Different steps when you\'re open or closed.', 'autoReplies', () => <String, dynamic>{
        'rules': <Json>[<String, dynamic>{'if': <String, dynamic>{'kind': 'business_hours', 'value': 'open'}, 'next': ''}],
        'else': '',
      }),
  const StepKind('delay', 'Wait', Icons.hourglass_empty, 'Pause before the next step.', 'followups'),
  const StepKind('tag', 'Tag customer', Icons.sell_outlined, 'Label the customer, e.g. lead or vip.', 'tagging'),
  const StepKind('capture', 'Save customer detail', Icons.badge_outlined, 'Store a field on the customer record.', 'customerCapture'),
  const StepKind('assign', 'Assign to staff', Icons.person_add_alt, 'Give the chat to a team member.', 'team'),
  const StepKind('followup', 'Follow-up reminder', Icons.notifications_active_outlined, 'Message later if they haven\'t replied.', 'followups'),
  const StepKind('handoff', 'Hand to staff', Icons.support_agent, 'Stop automation and alert your team.', 'handoff'),
  const StepKind('track', 'Track result', Icons.flag_outlined, 'Count an order or lead in Insights.', 'orders'),
  const StepKind('goto', 'Go to step', Icons.redo, 'Jump to another step.', 'autoReplies'),
  const StepKind('ai_reply', 'AI reply', Icons.auto_awesome, 'Let AI answer using your instructions.', 'ai'),
  const StepKind('webhook', 'Send to another app', Icons.webhook, 'POST the data to a URL (Sheets, Zapier…).', 'integrations'),
  const StepKind('end', 'End', Icons.stop_circle_outlined, 'Finish the workflow.', 'autoReplies'),
];

StepKind kindOf(Json n) {
  final String t = str(n['type']);
  if (t == 'condition') {
    final List<Json> rules = asList(n['rules']);
    if (rules.length == 1 && asMap(rules.first['if'])['kind'] == 'business_hours') return stepKinds[3];
  }
  return stepKinds.firstWhere((StepKind k) => k.type == t, orElse: () => stepKinds.first);
}

String stepSummary(Json n) => switch (str(n['type'])) {
      'message' || 'handoff' => str(n['text']),
      'question' => '${str(n['text'])}  → saves {{${str(n['saveAs'])}}}',
      'delay' => '${intOf(n['minutes'])} minutes',
      'followup' => 'After ${intOf(n['minutes'])} min: ${str(n['text'])}',
      'tag' => '${n['remove'] == true ? 'Remove' : 'Add'}: ${asStrings(n['tags']).join(', ')}',
      'capture' => '${str(n['field'])} = ${str(n['value'])}',
      'track' => str(n['event']).replaceAll('_', ' '),
      'goto' => 'Go to ${str(n['target'])}',
      'assign' => str(n['to']) == 'round_robin' || str(n['to']).isEmpty ? 'Next available staff' : 'Specific staff member',
      'condition' => asList(n['rules']).map((Json r) => ruleText(asMap(r['if']))).join(' / '),
      'ai_reply' => str(n['instructions']),
      'webhook' => str(n['url']),
      _ => '',
    };

String ruleText(Json r) => switch (str(r['kind'])) {
      'business_hours' => r['value'] == 'closed' ? 'If closed' : 'If open',
      'tag' => 'If tagged ${str(r['value'])}',
      'new_customer' => 'If new customer',
      _ => 'If ${str(r['var'])} ${str(r['op']).isEmpty ? 'eq' : str(r['op'])} ${str(r['value'])}',
    };

String newStepId() => 's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

class FlowEditorScreen extends StatefulWidget {
  const FlowEditorScreen({this.flowId, this.draft, super.key});

  final String? flowId;
  final Json? draft;

  @override
  State<FlowEditorScreen> createState() => _FlowEditorScreenState();
}

class _FlowEditorScreenState extends State<FlowEditorScreen> {
  String? _id;
  String _name = '';
  Json _trigger = <String, dynamic>{'type': 'keyword', 'keywords': <String>[]};
  List<Json> _nodes = <Json>[];
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  List<String> _errors = <String>[];
  int _nameVersion = 0;

  @override
  void initState() {
    super.initState();
    _id = widget.flowId;
    _load();
  }

  void _apply(Json f) {
    _name = str(f['name']);
    _trigger = asMap(f['trigger']);
    if (_trigger.isEmpty) _trigger = <String, dynamic>{'type': 'keyword', 'keywords': <String>[]};
    _nodes = asList(f['nodes']);
    _nameVersion++;
  }

  Future<void> _load() async {
    try {
      if (_id != null) {
        _apply(await apiOf(context).get('/flows/$_id'));
      } else if (widget.draft != null) {
        _apply(widget.draft!);
        _dirty = true;
      }
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
    if (mounted) setState(() => _loading = false);
  }

  void _changed(VoidCallback f) => setState(() {
        f();
        _dirty = true;
      });

  Future<bool> _save() async {
    setState(() => _saving = true);
    final Json body = <String, dynamic>{'name': _name, 'trigger': _trigger, 'nodes': _nodes};
    try {
      final BusinessApi api = apiOf(context);
      final Json r = _id == null ? await api.post('/businesses/${sessionOf(context).bid}/flows', body) : await api.put('/flows/$_id', body);
      _id = str(r['id']);
      _dirty = false;
      _errors = <String>[];
      if (mounted) {
        final List<String> w = asStrings(r['warnings']);
        toast(context, w.isEmpty ? 'Saved' : 'Saved. Note: ${w.first}');
      }
      return true;
    } on BusinessApiException catch (e) {
      if (e.isUpgrade) {
        if (mounted) await showBusinessError(context, e);
      } else {
        setState(() => _errors = e.errors.isEmpty ? <String>[e.message] : e.errors);
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _test() async {
    if ((_dirty || _id == null) && !await _save()) return;
    if (!mounted || _id == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => TestConsoleScreen(flowId: _id!, flowName: _name)));
  }

  Future<void> _delete() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('Delete workflow?'),
        content: const Text('Customers in the middle of it will stop receiving its messages.'),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete'))],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await apiOf(context).delete('/flows/$_id');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
  }

  Future<void> _addStep() async {
    final bool Function(String) can = sessionOf(context).can;
    final StepKind? k = await showModalBottomSheet<StepKind>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (BuildContext c, ScrollController sc) => ListView(controller: sc, children: <Widget>[
          for (final StepKind k in stepKinds)
            ListTile(
              leading: Icon(k.icon, color: can(k.feature) ? AutometaColors.accent : null),
              title: Text(k.label),
              subtitle: Text(k.help),
              trailing: can(k.feature) ? null : const Icon(Icons.lock_outline, size: 18, color: AutometaColors.secondary),
              onTap: () => Navigator.pop(c, k),
            ),
        ]),
      ),
    );
    if (k == null || !mounted) return;
    final Json n = <String, dynamic>{'id': newStepId(), 'type': k.type, ...?k.preset?.call()};
    if (k.type == 'question') n.addAll(<String, dynamic>{'input': 'text', 'saveAs': 'answer${_nodes.length + 1}'});
    if (k.type == 'delay' || k.type == 'followup') n['minutes'] = k.type == 'delay' ? 10 : 1440;
    if (k.type == 'followup') n['ifNoReply'] = true;
    if (k.type == 'assign') n['to'] = 'round_robin';
    if (k.type == 'track') n['event'] = 'order_started';
    final Json? edited = await _editStep(n, isNew: true);
    if (edited != null) _changed(() => _nodes.add(edited));
  }

  Future<Json?> _editStep(Json n, {bool isNew = false}) async {
    final Object? r = await Navigator.of(context).push<Object>(MaterialPageRoute<Object>(builder: (_) => StepEditorScreen(node: n, all: _nodes, isNew: isNew)));
    if (r == 'delete') {
      _changed(() => _nodes.removeWhere((Json x) => x['id'] == n['id']));
      return null;
    }
    return r is Map ? asMap(r) : null;
  }

  @override
  Widget build(BuildContext context) {
    final bool canEdit = sessionOf(context).allowed('flows.write');
    final String type = str(_trigger['type']);
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (bool didPop, Object? _) async {
        if (didPop) return;
        final bool? leave = await showDialog<bool>(
          context: context,
          builder: (BuildContext c) => AlertDialog(
            title: const Text('Discard changes?'),
            actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard'))],
          ),
        );
        if (leave == true && context.mounted) {
          setState(() => _dirty = false);
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_id == null ? 'New workflow' : 'Edit workflow'),
          actions: <Widget>[
            TextButton.icon(onPressed: _loading ? null : _test, icon: const Icon(Icons.science_outlined), label: const Text('Test')),
            if (canEdit) IconButton(tooltip: 'Save', onPressed: _saving || _loading ? null : _save, icon: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_outlined)),
            if (_id != null && canEdit) PopupMenuButton<String>(onSelected: (_) => _delete(), itemBuilder: (_) => const <PopupMenuEntry<String>>[PopupMenuItem<String>(value: 'd', child: Text('Delete'))]),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: <Widget>[
                  if (_errors.isNotEmpty)
                    Panel(
                      borderColor: AutometaColors.danger,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        const Text('Fix these before saving:', style: TextStyle(fontWeight: FontWeight.w600, color: AutometaColors.danger)),
                        for (final String e in _errors) Text('• $e'),
                      ]),
                    ),
                  if (_errors.isNotEmpty) const SizedBox(height: 12),
                  TextFormField(
                    key: ValueKey<int>(_nameVersion),
                    initialValue: _name,
                    decoration: const InputDecoration(labelText: 'Workflow name'),
                    onChanged: (String v) => _changed(() => _name = v),
                  ),
                  const SizedBox(height: 16),
                  const SectionLabel('Starts when'),
                  Panel(
                    child: Column(children: <Widget>[
                      DropdownButtonFormField<String>(
                        value: const <String>['keyword', 'greeting', 'away_hours', 'fallback', 'button'].contains(type) ? type : 'keyword',
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Trigger'),
                        items: const <DropdownMenuItem<String>>[
                          DropdownMenuItem<String>(value: 'keyword', child: Text('Message contains a keyword')),
                          DropdownMenuItem<String>(value: 'greeting', child: Text('New customer\'s first message')),
                          DropdownMenuItem<String>(value: 'away_hours', child: Text('Message outside business hours')),
                          DropdownMenuItem<String>(value: 'fallback', child: Text('Nothing else matched')),
                        ],
                        onChanged: (String? v) => _changed(() => _trigger = <String, dynamic>{..._trigger, 'type': v}),
                      ),
                      if (type == 'keyword' || type == 'button') ...<Widget>[
                        const SizedBox(height: 12),
                        TextFormField(
                          initialValue: asStrings(_trigger['keywords']).join(', '),
                          decoration: const InputDecoration(labelText: 'Keywords', hintText: 'menu, order, price', helperText: 'Separate with commas. Case and punctuation don\'t matter.'),
                          onChanged: (String v) => _changed(() => _trigger['keywords'] = v.split(',').map((String e) => e.trim()).where((String e) => e.isNotEmpty).toList()),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          value: str(_trigger['hours']).isEmpty ? 'any' : str(_trigger['hours']),
                          isExpanded: true,
                          decoration: const InputDecoration(labelText: 'Only run'),
                          items: const <DropdownMenuItem<String>>[
                            DropdownMenuItem<String>(value: 'any', child: Text('Any time')),
                            DropdownMenuItem<String>(value: 'open', child: Text('During business hours')),
                            DropdownMenuItem<String>(value: 'closed', child: Text('Outside business hours')),
                          ],
                          onChanged: (String? v) => _changed(() => _trigger['hours'] = v),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 16),
                  SectionLabel('Steps (${_nodes.length})'),
                  if (_nodes.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Add the first step, e.g. "Send message".')),
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: canEdit,
                    onReorder: (int a, int b) => _changed(() {
                      final Json n = _nodes.removeAt(a);
                      _nodes.insert(b > a ? b - 1 : b, n);
                    }),
                    children: <Widget>[
                      for (int i = 0; i < _nodes.length; i++)
                        Padding(
                          key: ValueKey<String>(str(_nodes[i]['id'])),
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _StepCard(
                            index: i,
                            node: _nodes[i],
                            all: _nodes,
                            onTap: !canEdit ? null : () async {
                              final Json? e = await _editStep(_nodes[i]);
                              if (e != null) _changed(() => _nodes[_nodes.indexWhere((Json x) => x['id'] == e['id'])] = e);
                            },
                          ),
                        ),
                    ],
                  ),
                  if (canEdit) OutlinedButton.icon(onPressed: _addStep, icon: const Icon(Icons.add), label: const Text('Add step')),
                ],
              ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.index, required this.node, required this.all, this.onTap});

  final int index;
  final Json node;
  final List<Json> all;
  final VoidCallback? onTap;

  String _label(String id) {
    final int i = all.indexWhere((Json n) => n['id'] == id);
    return i < 0 ? 'missing step!' : 'step ${i + 1}';
  }

  @override
  Widget build(BuildContext context) {
    final StepKind k = kindOf(node);
    final List<String> branches = <String>[
      for (final Json c in asList(node['choices'])) if (str(c['next']).isNotEmpty) '"${str(c['label'])}" → ${_label(str(c['next']))}',
      for (final Json r in asList(node['rules'])) if (str(r['next']).isNotEmpty) '${ruleText(asMap(r['if']))} → ${_label(str(r['next']))}',
      if (str(node['else']).isNotEmpty) 'Otherwise → ${_label(str(node['else']))}',
      if (str(node['next']).isNotEmpty) 'Then → ${_label(str(node['next']))}',
    ];
    return Panel(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        CircleAvatar(radius: 16, backgroundColor: AutometaColors.accent.withValues(alpha: 0.14), child: Icon(k.icon, size: 18, color: AutometaColors.accent)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('${index + 1}. ${k.label}', style: Theme.of(context).textTheme.titleSmall),
            if (stepSummary(node).isNotEmpty) Text(stepSummary(node), maxLines: 3, overflow: TextOverflow.ellipsis),
            for (final String b in branches) Text(b, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AutometaColors.secondary)),
          ]),
        ),
        const SizedBox(width: 28),
      ]),
    );
  }
}

/// Form for one step. Pops with the edited map, 'delete', or null.
class StepEditorScreen extends StatefulWidget {
  const StepEditorScreen({required this.node, required this.all, this.isNew = false, super.key});

  final Json node;
  final List<Json> all;
  final bool isNew;

  @override
  State<StepEditorScreen> createState() => _StepEditorScreenState();
}

class _StepEditorScreenState extends State<StepEditorScreen> {
  late final Json n = asMap(Map<String, dynamic>.of(widget.node));
  late final List<Json> choices = asList(n['choices']);
  late final List<Json> rules = asList(n['rules']).map((Json r) => <String, dynamic>{...r, 'if': asMap(r['if'])}).toList();

  Widget _text(String key, String label, {String hint = '', int lines = 1, bool number = false, String help = ''}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          initialValue: str(n[key]),
          minLines: lines,
          maxLines: lines == 1 ? 1 : 10,
          keyboardType: number ? TextInputType.number : null,
          decoration: InputDecoration(labelText: label, hintText: hint, helperText: help.isEmpty ? null : help, helperMaxLines: 3),
          onChanged: (String v) => n[key] = number ? int.tryParse(v) : v,
        ),
      );

  Widget _switch(String key, String label, [String sub = '']) => SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: sub.isEmpty ? null : Text(sub),
        value: n[key] == true,
        onChanged: (bool v) => setState(() => n[key] = v),
      );

  Widget _target(String label, String value, ValueChanged<String> onChanged, {String emptyLabel = 'Next step'}) {
    final List<Json> others = widget.all.where((Json x) => x['id'] != n['id']).toList();
    final bool known = value.isEmpty || others.any((Json x) => x['id'] == value);
    return DropdownButtonFormField<String>(
      value: known ? value : '',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: <DropdownMenuItem<String>>[
        DropdownMenuItem<String>(value: '', child: Text(emptyLabel)),
        for (final Json o in others)
          DropdownMenuItem<String>(value: str(o['id']), child: Text('Step ${widget.all.indexOf(o) + 1}: ${kindOf(o).label} ${stepSummary(o)}', overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (String? v) => setState(() => onChanged(v ?? '')),
    );
  }

  Widget _drop(String key, String label, List<(String, String)> opts) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String>(
          value: opts.any(((String, String) o) => o.$1 == str(n[key])) ? str(n[key]) : opts.first.$1,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: <DropdownMenuItem<String>>[for (final (String v, String l) in opts) DropdownMenuItem<String>(value: v, child: Text(l))],
          onChanged: (String? v) => setState(() => n[key] = v),
        ),
      );

  List<Widget> _fields() {
    switch (str(n['type'])) {
      case 'message':
        return <Widget>[_text('text', 'Message', lines: 4, help: 'Placeholders: {{name}}, {{business}}, and any saved answer like {{item}}.')];
      case 'question':
        final String input = str(n['input']).isEmpty ? 'text' : str(n['input']);
        return <Widget>[
          _text('text', 'Question', lines: 3),
          _drop('input', 'Answer type', const <(String, String)>[('text', 'Free text'), ('choice', 'Buttons / choices'), ('number', 'Number'), ('phone', 'Phone number')]),
          _text('saveAs', 'Save answer as', hint: 'item', help: 'Use later as {{name-you-type}}. Letters, numbers and _ only.'),
          if (input == 'number') ...<Widget>[_text('min', 'Minimum', number: true), _text('max', 'Maximum', number: true)],
          if (input == 'choice') ...<Widget>[
            const SectionLabel('Choices'),
            Text('Up to 3 show as WhatsApp buttons, up to 10 as a list. Customers can also type the number or the text.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            for (int i = 0; i < choices.length; i++)
              Panel(
                key: ObjectKey(choices[i]),
                padding: const EdgeInsets.all(12),
                child: Column(children: <Widget>[
                  Row(children: <Widget>[
                    Expanded(child: TextFormField(initialValue: str(choices[i]['label']), maxLength: 24, decoration: InputDecoration(labelText: 'Choice ${i + 1}'), onChanged: (String v) => choices[i]['label'] = v)),
                    IconButton(onPressed: () => setState(() => choices.removeAt(i)), icon: const Icon(Icons.close)),
                  ]),
                  _target('Then go to', str(choices[i]['next']), (String v) => choices[i]['next'] = v),
                ]),
              ),
            TextButton.icon(onPressed: () => setState(() => choices.add(<String, dynamic>{'label': ''})), icon: const Icon(Icons.add), label: const Text('Add choice')),
          ],
          _switch('saveToCustomer', 'Also save on the customer\'s record', 'Shows in their details next time'),
        ];
      case 'condition':
        return <Widget>[
          for (int i = 0; i < rules.length; i++) _ruleEditor(i),
          TextButton.icon(onPressed: () => setState(() => rules.add(<String, dynamic>{'if': <String, dynamic>{'kind': 'var', 'op': 'eq'}, 'next': ''})), icon: const Icon(Icons.add), label: const Text('Add rule')),
          const SizedBox(height: 8),
          _target('Otherwise go to', str(n['else']), (String v) => n['else'] = v),
        ];
      case 'delay':
        return <Widget>[_text('minutes', 'Wait (minutes)', number: true)];
      case 'tag':
        return <Widget>[
          TextFormField(
            initialValue: asStrings(n['tags']).join(', '),
            decoration: const InputDecoration(labelText: 'Tags', hintText: 'lead, vip'),
            onChanged: (String v) => n['tags'] = v.split(',').map((String e) => e.trim()).where((String e) => e.isNotEmpty).toList(),
          ),
          _switch('remove', 'Remove these tags instead'),
        ];
      case 'capture':
        return <Widget>[
          _text('field', 'Field', hint: 'address, email, lead_status'),
          _text('value', 'Value', hint: '{{address}}', help: 'Usually a saved answer like {{address}}.'),
          _switch('lead', 'Count as a new lead in Insights'),
        ];
      case 'track':
        return <Widget>[_drop('event', 'What happened', const <(String, String)>[('order_started', 'Order started'), ('order_completed', 'Order completed'), ('lead_captured', 'Lead captured')])];
      case 'assign':
        return <Widget>[_drop('to', 'Assign to', const <(String, String)>[('round_robin', 'Next available staff (rotate)')])];
      case 'followup':
        return <Widget>[
          _text('minutes', 'Send after (minutes)', number: true, help: '1440 = 1 day. Within 24 h of their last message it\'s sent as text; later, only an approved template can be sent.'),
          _text('text', 'Message', lines: 3),
          _text('template', 'Approved template name (optional)', hint: 'order_followup', help: 'Used when the 24-hour window has closed.'),
          _switch('ifNoReply', 'Only if they haven\'t replied'),
        ];
      case 'handoff':
        return <Widget>[_text('text', 'Message to customer', lines: 2, hint: 'A team member will reply shortly.'), _text('reason', 'Note for staff', hint: 'New order to confirm')];
      case 'goto':
        return <Widget>[_target('Go to', str(n['target']), (String v) => n['target'] = v, emptyLabel: 'Choose a step')];
      case 'ai_reply':
        return <Widget>[_text('instructions', 'Instructions for AI', lines: 4, hint: 'Answer questions about our menu. Never promise delivery times.'), _text('fallbackText', 'If AI is unavailable, send', lines: 2)];
      case 'webhook':
        return <Widget>[_text('url', 'HTTPS URL', hint: 'https://hooks.zapier.com/...', help: 'Receives customer details and saved answers as JSON.')];
      default:
        return <Widget>[const Text('This step has no settings.')];
    }
  }

  Widget _ruleEditor(int i) {
    final Json r = rules[i];
    final Json c = asMap(r['if']);
    r['if'] = c;
    final String kind = str(c['kind']).isEmpty ? 'var' : str(c['kind']);
    return Panel(
      key: ObjectKey(r),
      padding: const EdgeInsets.all(12),
      child: Column(children: <Widget>[
        Row(children: <Widget>[
          Expanded(
            child: DropdownButtonFormField<String>(
              value: kind,
              isExpanded: true,
              decoration: InputDecoration(labelText: 'Rule ${i + 1}: check'),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(value: 'var', child: Text('A saved answer / field')),
                DropdownMenuItem<String>(value: 'business_hours', child: Text('Business hours')),
                DropdownMenuItem<String>(value: 'tag', child: Text('Customer has tag')),
                DropdownMenuItem<String>(value: 'new_customer', child: Text('Is a new customer')),
              ],
              onChanged: (String? v) => setState(() => c['kind'] = v),
            ),
          ),
          IconButton(onPressed: () => setState(() => rules.removeAt(i)), icon: const Icon(Icons.close)),
        ]),
        if (kind == 'var') ...<Widget>[
          TextFormField(initialValue: str(c['var']), decoration: const InputDecoration(labelText: 'Answer name', hintText: 'fulfilment'), onChanged: (String v) => c['var'] = v),
          DropdownButtonFormField<String>(
            value: str(c['op']).isEmpty ? 'eq' : str(c['op']),
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'is'),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'eq', child: Text('equal to')),
              DropdownMenuItem<String>(value: 'neq', child: Text('not equal to')),
              DropdownMenuItem<String>(value: 'contains', child: Text('contains any of')),
              DropdownMenuItem<String>(value: 'gt', child: Text('more than')),
              DropdownMenuItem<String>(value: 'lt', child: Text('less than')),
              DropdownMenuItem<String>(value: 'exists', child: Text('filled in')),
              DropdownMenuItem<String>(value: 'empty', child: Text('empty')),
            ],
            onChanged: (String? v) => setState(() => c['op'] = v),
          ),
          if (c['op'] != 'exists' && c['op'] != 'empty') TextFormField(initialValue: str(c['value']), decoration: const InputDecoration(labelText: 'Value'), onChanged: (String v) => c['value'] = v),
        ],
        if (kind == 'business_hours')
          DropdownButtonFormField<String>(
            value: c['value'] == 'closed' ? 'closed' : 'open',
            decoration: const InputDecoration(labelText: 'When'),
            items: const <DropdownMenuItem<String>>[DropdownMenuItem<String>(value: 'open', child: Text('Open')), DropdownMenuItem<String>(value: 'closed', child: Text('Closed'))],
            onChanged: (String? v) => setState(() => c['value'] = v),
          ),
        if (kind == 'tag') TextFormField(initialValue: str(c['value']), decoration: const InputDecoration(labelText: 'Tag'), onChanged: (String v) => c['value'] = v),
        const SizedBox(height: 8),
        _target('Then go to', str(r['next']), (String v) => r['next'] = v),
      ]),
    );
  }

  void _done() {
    if (str(n['type']) == 'question') {
      n['choices'] = choices
          .where((Json c) => str(c['label']).trim().isNotEmpty)
          .map((Json c) => <String, dynamic>{...c, 'value': str(c['value']).isEmpty ? str(c['label']).trim().toLowerCase() : c['value']})
          .toList();
      if (str(n['input']).isEmpty) n['input'] = 'text';
    }
    if (str(n['type']) == 'condition') n['rules'] = rules;
    n.removeWhere((String k, dynamic v) => v == null || (v is String && v.isEmpty && k != 'text'));
    Navigator.of(context).pop(n);
  }

  @override
  Widget build(BuildContext context) {
    final StepKind k = kindOf(n);
    final bool locked = !sessionOf(context).can(k.feature);
    return Scaffold(
      appBar: AppBar(
        title: Text(k.label),
        actions: <Widget>[
          if (!widget.isNew) IconButton(tooltip: 'Delete step', onPressed: () => Navigator.of(context).pop('delete'), icon: const Icon(Icons.delete_outline)),
          TextButton(onPressed: _done, child: const Text('Done')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(k.help, style: Theme.of(context).textTheme.bodyMedium),
          if (locked)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: StatusPill(label: 'Needs a higher plan to run', color: AutometaColors.secondary, icon: Icons.lock_outline),
            ),
          const SizedBox(height: 16),
          ..._fields(),
          if (!const <String>['goto', 'end', 'handoff', 'condition'].contains(str(n['type'])) && str(n['input']) != 'choice') ...<Widget>[
            const SizedBox(height: 8),
            _target('After this step', str(n['next']), (String v) => n['next'] = v),
          ],
        ],
      ),
    );
  }
}

/// Plays messages through the real engine on the server with a throwaway
/// test customer: nothing is sent to WhatsApp and nothing is counted.
class TestConsoleScreen extends StatefulWidget {
  const TestConsoleScreen({required this.flowId, required this.flowName, super.key});

  final String flowId;
  final String flowName;

  @override
  State<TestConsoleScreen> createState() => _TestConsoleScreenState();
}

class _TestConsoleScreenState extends State<TestConsoleScreen> {
  final List<String> _sent = <String>[];
  final TextEditingController _c = TextEditingController();
  Json? _result;
  bool _busy = false;

  Future<void> _send([String? text]) async {
    final String t = (text ?? _c.text).trim();
    if (t.isEmpty) return;
    setState(() { _busy = true; _sent.add(t); });
    _c.clear();
    try {
      final Json r = await apiOf(context).post('/flows/${widget.flowId}/test', <String, dynamic>{'messages': _sent});
      if (mounted) setState(() => _result = r);
    } catch (e) {
      _sent.removeLast();
      if (mounted) await showBusinessError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Json> transcript = asList(_result?['transcript']);
    final String status = str(_result?['status']);
    return Scaffold(
      appBar: AppBar(
        title: Text('Test: ${widget.flowName}', overflow: TextOverflow.ellipsis),
        actions: <Widget>[IconButton(tooltip: 'Restart', onPressed: () => setState(() { _sent.clear(); _result = null; }), icon: const Icon(Icons.restart_alt))],
      ),
      body: Column(children: <Widget>[
        Container(
          width: double.infinity,
          color: AutometaColors.info.withValues(alpha: 0.12),
          padding: const EdgeInsets.all(10),
          child: const Text('Test mode: nothing is sent to WhatsApp and nothing counts in Insights. Delays are skipped.'),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: <Widget>[
              if (transcript.isEmpty) const Text('Type what a customer would send, e.g. the trigger keyword.'),
              for (final Json m in transcript)
                Align(
                  alignment: m['from'] == 'customer' ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.all(10),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: (m['from'] == 'customer' ? AutometaColors.accent : m['from'] == 'system' ? AutometaColors.warning : AutometaColors.secondary).withValues(alpha: 0.15),
                    ),
                    child: Text(str(m['text'])),
                  ),
                ),
              if (_result != null) ...<Widget>[
                const SizedBox(height: 12),
                Row(children: <Widget>[
                  Icon(runIcon(status), color: runColor(status)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(status == 'waiting' ? 'Waiting for the customer\'s answer' : 'Result: $status${str(_result?['error']).isEmpty ? '' : ' (${_result?['error']})'}')),
                ]),
                ExpansionTile(title: const Text('Step-by-step trace'), children: <Widget>[TraceList(trace: asList(_result?['trace']))]),
                if (asMap(_result?['customerAfter']).isNotEmpty)
                  ExpansionTile(
                    title: const Text('Customer record after'),
                    children: <Widget>[
                      for (final MapEntry<String, dynamic> e in asMap(asMap(_result?['customerAfter'])['fields']).entries) LabeledValue(label: e.key, value: str(e.value)),
                      LabeledValue(label: 'Tags', value: asStrings(asMap(_result?['customerAfter'])['tags']).join(', ')),
                      LabeledValue(label: 'Status', value: str(asMap(_result?['customerAfter'])['status'])),
                    ],
                  ),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: <Widget>[
              Expanded(child: TextField(controller: _c, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Message as the customer'))),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: _busy ? null : _send, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
