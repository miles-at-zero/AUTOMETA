import 'package:flutter/material.dart';

import '../../../business/business_api.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';

class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  String _status = 'all';
  final GlobalKey<LoaderState<List<Json>>> _key = GlobalKey<LoaderState<List<Json>>>();

  @override
  Widget build(BuildContext context) {
    final String bid = sessionOf(context).bid;
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: <Widget>[
              for (final (String v, String l) in <(String, String)>[('all', 'All'), ('needs_human', 'Needs you'), ('open', 'Automated'), ('closed', 'Closed')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(label: Text(l), selected: _status == v, onSelected: (_) {
                    setState(() => _status = v);
                    _key.currentState?.reload();
                  }),
                ),
            ],
          ),
        ),
        Expanded(
          child: Loader<List<Json>>(
            key: _key,
            load: () => apiOf(context).list('/businesses/$bid/conversations?status=$_status'),
            builder: (BuildContext context, List<Json> rows, Future<void> Function() reload) {
              if (rows.isEmpty) {
                return ListView(children: const <Widget>[
                  SizedBox(height: 80),
                  EmptyState(icon: Icons.forum_outlined, title: 'No conversations yet', message: 'When customers message your WhatsApp Business number, they appear here. Chats that need a person are shown first.'),
                ]);
              }
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int i) {
                  final Json c = rows[i];
                  final bool needs = c['status'] == 'needs_human';
                  final String name = str(c['name']).isEmpty ? '+${c['waId']}' : str(c['name']);
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundColor: (needs ? AutometaColors.warning : AutometaColors.accent).withValues(alpha: 0.18),
                      child: Text(name.characters.first.toUpperCase(), style: TextStyle(color: needs ? AutometaColors.warning : AutometaColors.accent)),
                    ),
                    title: Row(children: <Widget>[
                      Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text(ago(c['lastSeen']), style: Theme.of(context).textTheme.bodySmall),
                    ]),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('${c['lastDirection'] == 'out' ? 'You: ' : ''}${str(c['lastText'])}', maxLines: 1, overflow: TextOverflow.ellipsis),
                        if (needs || asStrings(c['tags']).isNotEmpty || str(c['category']).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(spacing: 4, runSpacing: 4, children: <Widget>[
                              if (needs) const StatusPill(label: 'Needs you', color: AutometaColors.warning),
                              if (str(c['category']).isNotEmpty) StatusPill(label: str(c['category']), color: AutometaColors.info),
                              for (final String t in asStrings(c['tags']).take(3)) StatusPill(label: t, color: AutometaColors.secondary),
                            ]),
                          ),
                      ],
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ConversationScreen(customerId: str(c['id']))));
                      await reload();
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({required this.customerId, super.key});

  final String customerId;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _text = TextEditingController();
  final GlobalKey<LoaderState<Json>> _key = GlobalKey<LoaderState<Json>>();
  bool _busy = false;

  String get _path => '/customers/${widget.customerId}';

  Future<void> _act(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
      await _key.currentState?.reload();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _act(() async {
        final String t = _text.text.trim();
        if (t.isEmpty) return;
        await apiOf(context).post('$_path/reply', <String, dynamic>{'text': t});
        _text.clear();
      });

  Future<void> _ai(String task) => _act(() async {
        final Json r = await apiOf(context).post('$_path/ai/$task');
        if (!mounted) return;
        if (task == 'summary') {
          await showDialog<void>(context: context, builder: (BuildContext c) => AlertDialog(title: const Text('Summary'), content: SelectableText(str(r['text'])), actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))]));
        } else {
          _text.text = str(r['text']);
          toast(context, 'Draft added. Check it before sending.');
        }
      });

  Future<void> _menu(String v, Json c) async {
    final BusinessApi api = apiOf(context);
    switch (v) {
      case 'resolve':
        await _act(() async => api.patch(_path, <String, dynamic>{'status': 'open'}));
      case 'close':
        await _act(() async => api.patch(_path, <String, dynamic>{'status': 'closed'}));
      case 'human':
        await _act(() async => api.patch(_path, <String, dynamic>{'status': 'needs_human'}));
      case 'tags':
        final String? t = await promptText(context, 'Tags', initial: asStrings(c['tags']).join(', '), hint: 'vip, lead, paid');
        if (t != null) await _act(() async => api.patch(_path, <String, dynamic>{'tags': t.split(',').map((String e) => e.trim()).where((String e) => e.isNotEmpty).toList()}));
      case 'assign':
        final List<Json> team = await api.list('/team');
        if (!mounted) return;
        final String? who = await showModalBottomSheet<String>(
          context: context,
          builder: (BuildContext ctx) => SafeArea(
            child: ListView(shrinkWrap: true, children: <Widget>[
              ListTile(leading: const Icon(Icons.person_off_outlined), title: const Text('Unassigned'), onTap: () => Navigator.pop(ctx, '')),
              for (final Json m in team.where((Json m) => m['active'] == true))
                ListTile(leading: const Icon(Icons.person_outline), title: Text(str(m['name'])), subtitle: Text(str(m['role'])), onTap: () => Navigator.pop(ctx, str(m['id']))),
            ]),
          ),
        );
        if (who != null) await _act(() async => api.patch(_path, <String, dynamic>{'assignedTo': who.isEmpty ? null : who}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool ai = sessionOf(context).can('ai');
    return Material(child: Loader<Json>(
      key: _key,
      load: () => apiOf(context).get(_path),
      builder: (BuildContext context, Json c, Future<void> Function() reload) {
        final List<Json> msgs = asList(c['messages']);
        final Json fields = asMap(c['fields']);
        final bool canReply = c['canReply'] == true;
        final String name = str(c['name']).isEmpty ? '+${c['waId']}' : str(c['name']);
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(name, overflow: TextOverflow.ellipsis),
              Text('+${c['waId']} · ${c['status'] == 'needs_human' ? 'waiting for you' : str(c['status'])}', style: Theme.of(context).textTheme.bodySmall),
            ]),
            actions: <Widget>[
              if (ai) IconButton(tooltip: 'AI summary', icon: const Icon(Icons.summarize_outlined), onPressed: _busy ? null : () => _ai('summary')),
              PopupMenuButton<String>(
                onSelected: (String v) => _menu(v, c),
                itemBuilder: (_) => <PopupMenuEntry<String>>[
                  if (c['status'] == 'needs_human') const PopupMenuItem<String>(value: 'resolve', child: Text('Done: back to automation')) else const PopupMenuItem<String>(value: 'human', child: Text('Pause automation for this chat')),
                  const PopupMenuItem<String>(value: 'tags', child: Text('Edit tags')),
                  const PopupMenuItem<String>(value: 'assign', child: Text('Assign to staff')),
                  const PopupMenuItem<String>(value: 'close', child: Text('Close conversation')),
                ],
              ),
            ],
          ),
          body: Column(children: <Widget>[
            if (fields.isNotEmpty || asStrings(c['tags']).isNotEmpty)
              ExpansionTile(
                title: const Text('Customer details'),
                dense: true,
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: <Widget>[
                  for (final MapEntry<String, dynamic> f in fields.entries) LabeledValue(label: f.key, value: str(f.value)),
                  if (asStrings(c['tags']).isNotEmpty) LabeledValue(label: 'Tags', value: asStrings(c['tags']).join(', ')),
                ],
              ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: msgs.length,
                itemBuilder: (BuildContext context, int i) => _Bubble(m: msgs[msgs.length - 1 - i]),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: canReply
                    ? Row(children: <Widget>[
                        if (ai) IconButton(tooltip: 'AI draft', icon: const Icon(Icons.auto_awesome, color: AutometaColors.secondary), onPressed: _busy ? null : () => _ai('draft')),
                        Expanded(child: TextField(controller: _text, minLines: 1, maxLines: 5, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(hintText: 'Reply as your business'))),
                        IconButton.filled(onPressed: _busy ? null : _send, icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send)),
                      ])
                    : const ListTile(
                        leading: Icon(Icons.lock_clock, color: AutometaColors.warning),
                        title: Text('24-hour window closed'),
                        subtitle: Text('WhatsApp only allows approved template messages until the customer writes again.'),
                      ),
              ),
            ),
          ]),
        );
      },
    ));
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m});

  final Json m;

  @override
  Widget build(BuildContext context) {
    final bool out = m['direction'] == 'out';
    final bool auto = intOf(m['automated']) == 1;
    final bool failed = m['status'] == 'failed';
    final Color bg = out ? (auto ? AutometaColors.secondary : AutometaColors.accent).withValues(alpha: 0.16) : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Align(
      alignment: out ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: failed ? Border.all(color: AutometaColors.danger) : null),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SelectableText(str(m['text'])),
          const SizedBox(height: 2),
          Text(
            <String>[if (out) auto ? 'Automation' : 'Staff', ago(m['createdAt']), if (out && str(m['status']).isNotEmpty) str(m['status']), if (failed) str(m['error'])].where((String e) => e.isNotEmpty).join(' · '),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: failed ? AutometaColors.danger : null),
          ),
        ]),
      ),
    );
  }
}
