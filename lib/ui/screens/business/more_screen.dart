import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../business/business_api.dart';
import '../../../business/business_session.dart';
import '../../../core/theme/design_tokens.dart';
import '../../widgets/autometa_widgets.dart';
import 'business_common.dart';
import 'plans_screen.dart';

class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final BusinessSession s = context.watch<BusinessSession>();
    Future<void> push(Widget w) async {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangeNotifierProvider<BusinessSession>.value(value: s, child: w)));
      try {
        await s.refresh();
      } catch (_) {}
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        const SectionLabel('Business'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(children: <Widget>[
            if (s.businesses.length > 1 || s.can('multiBusiness'))
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('Switch business'),
                subtitle: Text(str(s.business['name'])),
                onTap: () => showModalBottomSheet<void>(
                  context: context,
                  builder: (BuildContext c) => SafeArea(
                    child: ListView(shrinkWrap: true, children: <Widget>[
                      for (final Json b in s.businesses)
                        ListTile(
                          leading: Icon(b['id'] == s.bid ? Icons.radio_button_checked : Icons.radio_button_off),
                          title: Text(str(b['name'])),
                          subtitle: Text(b['connected'] == true ? str(b['displayPhone']) : 'Not connected'),
                          onTap: () {
                            s.selectBusiness(str(b['id']));
                            Navigator.pop(c);
                          },
                        ),
                      if (s.allowed('*'))
                        ListTile(
                          leading: const Icon(Icons.add_business_outlined),
                          title: const Text('Add another business'),
                          onTap: () async {
                            Navigator.pop(c);
                            final String? name = await promptText(context, 'Business name');
                            if (name == null || name.trim().isEmpty || !context.mounted) return;
                            try {
                              final Json b = await s.api!.post('/businesses', <String, dynamic>{'name': name.trim()});
                              await s.refresh();
                              await s.selectBusiness(str(b['id']));
                            } catch (e) {
                              if (context.mounted) await showBusinessError(context, e);
                            }
                          },
                        ),
                    ]),
                  ),
                ),
              ),
            ListTile(
              leading: Icon(Icons.link, color: s.business['connected'] == true ? AutometaColors.success : AutometaColors.warning),
              title: const Text('WhatsApp number'),
              subtitle: Text(s.business['connected'] == true ? 'Connected ${str(s.business['displayPhone'])}' : 'Not connected'),
              trailing: const Icon(Icons.chevron_right),
              onTap: s.allowed('business.write') ? () => push(const ConnectNumberScreen()) : null,
            ),
            ListTile(leading: const Icon(Icons.schedule), title: const Text('Business hours & settings'), trailing: const Icon(Icons.chevron_right), onTap: s.allowed('business.write') ? () => push(const BusinessSettingsScreen()) : null),
            ListTile(leading: const Icon(Icons.quiz_outlined), title: const Text('FAQs'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const FaqScreen())),
          ]),
        ),
        const SizedBox(height: 12),
        const SectionLabel('Account'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(children: <Widget>[
            ListTile(leading: const Icon(Icons.workspace_premium_outlined, color: AutometaColors.secondary), title: const Text('Plan & billing'), subtitle: Text(s.planName), trailing: const Icon(Icons.chevron_right), onTap: () => push(const PlansScreen())),
            ListTile(leading: const Icon(Icons.group_outlined), title: const Text('Team'), subtitle: Text('You are ${s.role}'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const TeamScreen())),
            if (s.allowed('audit')) ListTile(leading: const Icon(Icons.policy_outlined), title: const Text('Audit log'), trailing: const Icon(Icons.chevron_right), onTap: () => push(const AuditScreen())),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Sign out of Business mode'),
              subtitle: Text(s.serverUrl),
              onTap: () async {
                final bool? ok = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext c) => AlertDialog(
                    title: const Text('Sign out?'),
                    content: const Text('Automations keep running on the server. You can sign in again with a new code from your owner or admin.'),
                    actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out'))],
                  ),
                );
                if (ok == true) await s.signOut();
              },
            ),
          ]),
        ),
      ],
    );
  }
}

class ConnectNumberScreen extends StatefulWidget {
  const ConnectNumberScreen({super.key});

  @override
  State<ConnectNumberScreen> createState() => _ConnectNumberScreenState();
}

class _ConnectNumberScreenState extends State<ConnectNumberScreen> {
  late final TextEditingController _id = TextEditingController(text: str(sessionOf(context).business['phoneNumberId']));
  final TextEditingController _token = TextEditingController();
  bool _busy = false;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final Json r = await apiOf(context).post('/businesses/${sessionOf(context).bid}/connect', <String, dynamic>{'phoneNumberId': _id.text.trim(), 'accessToken': _token.text.trim()});
      _token.clear();
      if (!mounted) return;
      await sessionOf(context).refresh();
      if (mounted) toast(context, 'Connected ${str(r['displayPhone'])} ${str(r['verifiedName'])}');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String server = sessionOf(context).serverUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect WhatsApp number')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text('Uses the official WhatsApp Business Platform (Cloud API). Customers message this number and AUTOMETA replies from it.'),
          const SizedBox(height: 12),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Text('One-time setup in Meta', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('1. developers.facebook.com → My Apps → Create app (Business) → add WhatsApp.\n'
                  '2. WhatsApp → API Setup: add your business phone number and copy its Phone number ID.\n'
                  '3. Business Settings → System users → add one with full control → Generate token with whatsapp_business_messaging and whatsapp_business_management. This token doesn\'t expire.'),
              const SizedBox(height: 6),
              const Text('4. WhatsApp → Configuration → Webhook. Your server operator sets the verify token and app secret:'),
              Row(children: <Widget>[
                Expanded(child: SelectableText('$server/webhook', style: const TextStyle(fontFamily: 'monospace'))),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: '$server/webhook'));
                    toast(context, 'Copied');
                  },
                ),
              ]),
              const Text('Then subscribe the webhook to "messages".'),
            ]),
          ),
          const SizedBox(height: 16),
          TextField(controller: _id, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Phone number ID', hintText: '1234567890123456')),
          const SizedBox(height: 12),
          TextField(
            controller: _token,
            obscureText: true,
            decoration: InputDecoration(labelText: 'Access token', helperText: sessionOf(context).business['connected'] == true ? 'Leave empty to keep the current token' : 'Stored encrypted on your server, never shown again'),
          ),
          const SizedBox(height: 20),
          PrimaryAction(label: 'Verify & connect', icon: Icons.verified_outlined, busy: _busy, onPressed: _busy ? null : _save),
        ],
      ),
    );
  }
}

class BusinessSettingsScreen extends StatefulWidget {
  const BusinessSettingsScreen({super.key});

  @override
  State<BusinessSettingsScreen> createState() => _BusinessSettingsScreenState();
}

class _BusinessSettingsScreenState extends State<BusinessSettingsScreen> {
  static const List<(String, String)> _days = <(String, String)>[('mon', 'Monday'), ('tue', 'Tuesday'), ('wed', 'Wednesday'), ('thu', 'Thursday'), ('fri', 'Friday'), ('sat', 'Saturday'), ('sun', 'Sunday')];
  late final Json _b = sessionOf(context).business;
  late String _name = str(_b['name']);
  late String _tz = str(_b['timezone']).isEmpty ? 'Africa/Lagos' : str(_b['timezone']);
  late final Map<String, List<String>> _hours = <String, List<String>>{
    for (final MapEntry<String, dynamic> e in asMap(_b['hours']).entries)
      if (e.value is List && (e.value as List<dynamic>).isNotEmpty) e.key: asStrings((e.value as List<dynamic>).first),
  };
  late bool _always = _hours.isEmpty;
  late final Json _settings = asMap(_b['settings']);
  bool _busy = false;

  Future<void> _pick(String day, int i) async {
    final List<String> r = _hours[day] ?? <String>['09:00', '18:00'];
    final List<String> p = r[i].split(':');
    final TimeOfDay? t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.tryParse(p[0]) ?? 9, minute: int.tryParse(p[1]) ?? 0));
    if (t == null) return;
    setState(() {
      r[i] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      _hours[day] = r;
    });
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await apiOf(context).patch('/businesses/${sessionOf(context).bid}', <String, dynamic>{
        'name': _name,
        'timezone': _tz,
        'hours': _always ? <String, dynamic>{} : <String, dynamic>{for (final MapEntry<String, List<String>> e in _hours.entries) e.key: <List<String>>[e.value]},
        'settings': _settings,
      });
      if (!mounted) return;
      await sessionOf(context).refresh();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Business settings'), actions: <Widget>[TextButton(onPressed: _busy ? null : _save, child: const Text('Save'))]),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            TextFormField(initialValue: _name, decoration: const InputDecoration(labelText: 'Business name'), onChanged: (String v) => _name = v),
            const SizedBox(height: 12),
            TextFormField(initialValue: _tz, decoration: const InputDecoration(labelText: 'Time zone', helperText: 'e.g. Africa/Lagos'), onChanged: (String v) => _tz = v.trim()),
            const SizedBox(height: 16),
            const SectionLabel('Opening hours'),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Always open'), subtitle: const Text('Away-hours replies never trigger'), value: _always, onChanged: (bool v) => setState(() => _always = v)),
            if (!_always)
              for (final (String d, String label) in _days)
                Row(children: <Widget>[
                  Switch(value: _hours.containsKey(d), onChanged: (bool v) => setState(() {
                    if (v) {
                      _hours[d] = <String>['09:00', '18:00'];
                    } else {
                      _hours.remove(d);
                    }
                  }),
                ),
                  Expanded(child: Text(label)),
                  if (_hours.containsKey(d)) ...<Widget>[
                    TextButton(onPressed: () => _pick(d, 0), child: Text(_hours[d]![0])),
                    const Text('–'),
                    TextButton(onPressed: () => _pick(d, 1), child: Text(_hours[d]![1])),
                  ] else
                    const Padding(padding: EdgeInsets.only(right: 12), child: Text('Closed')),
                ]),
            if (!_always) Text('Closing before opening (e.g. 18:00–02:00) means open overnight.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            const SectionLabel('Automation'),
            TextFormField(
              initialValue: str(_settings['cancelText']),
              decoration: const InputDecoration(labelText: 'Reply when a customer types "cancel"', hintText: 'Okay, cancelled. Send a message any time to start again.'),
              onChanged: (String v) => _settings['cancelText'] = v.isEmpty ? null : v,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Agents only see their assigned chats'),
              subtitle: Text(sessionOf(context).can('advancedPermissions') ? 'Plus unassigned ones' : 'Business plan'),
              value: _settings['agentsSeeAssignedOnly'] == true,
              onChanged: (bool v) => setState(() => _settings['agentsSeeAssignedOnly'] = v),
            ),
          ],
        ),
      );
}

class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  final GlobalKey<LoaderState<List<Json>>> _key = GlobalKey<LoaderState<List<Json>>>();

  Future<void> _edit([Json? f]) async {
    final TextEditingController k = TextEditingController(text: asStrings(f?['keywords']).join(', '));
    final TextEditingController a = TextEditingController(text: str(f?['answer']));
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text(f == null ? 'New FAQ' : 'Edit FAQ'),
        content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          TextField(controller: k, decoration: const InputDecoration(labelText: 'When the message mentions', hintText: 'price, how much, cost')),
          const SizedBox(height: 8),
          TextField(controller: a, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Answer')),
        ]),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save'))],
      ),
    );
    if (ok != true || !mounted) return;
    final Json body = <String, dynamic>{'keywords': k.text.split(',').map((String e) => e.trim()).where((String e) => e.isNotEmpty).toList(), 'answer': a.text.trim()};
    try {
      if (f == null) {
        await apiOf(context).post('/businesses/${sessionOf(context).bid}/faqs', body);
      } else {
        await apiOf(context).put('/faqs/${f['id']}', body);
      }
      await _key.currentState?.reload();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
  }

  Future<void> _suggest() async {
    try {
      final Json r = await apiOf(context).post('/businesses/${sessionOf(context).bid}/ai/faqs');
      if (!mounted) return;
      final List<Json> s = asList(r['faqs']);
      if (s.isEmpty) return toast(context, 'Not enough customer messages yet for suggestions.');
      for (final Json f in s) {
        if (!mounted) return;
        await _edit(f);
      }
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canEdit = sessionOf(context).allowed('faqs.write');
    return Scaffold(
      appBar: AppBar(title: const Text('FAQs'), actions: <Widget>[
        if (canEdit && sessionOf(context).can('ai')) IconButton(tooltip: 'AI suggestions from real chats', icon: const Icon(Icons.auto_awesome), onPressed: _suggest),
      ]),
      floatingActionButton: canEdit ? FloatingActionButton(onPressed: () => _edit(), child: const Icon(Icons.add)) : null,
      body: Loader<List<Json>>(
        key: _key,
        load: () => apiOf(context).list('/businesses/${sessionOf(context).bid}/faqs'),
        builder: (BuildContext context, List<Json> faqs, Future<void> Function() reload) => faqs.isEmpty
            ? ListView(children: const <Widget>[SizedBox(height: 80), EmptyState(icon: Icons.quiz_outlined, title: 'No FAQs yet', message: 'Answer common questions automatically: location, prices, opening hours, payment.')])
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: <Widget>[
                  for (final Json f in faqs)
                    Card(
                      child: ListTile(
                        title: Text(asStrings(f['keywords']).join(', ')),
                        subtitle: Text(str(f['answer']), maxLines: 3, overflow: TextOverflow.ellipsis),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                          Text('${intOf(f['hits'])}×'),
                          if (canEdit)
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () async {
                                await apiOf(context).delete('/faqs/${f['id']}');
                                await reload();
                              },
                            ),
                        ]),
                        onTap: canEdit ? () => _edit(f) : null,
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class TeamScreen extends StatefulWidget {
  const TeamScreen({super.key});

  @override
  State<TeamScreen> createState() => _TeamScreenState();
}

class _TeamScreenState extends State<TeamScreen> {
  final GlobalKey<LoaderState<List<Json>>> _key = GlobalKey<LoaderState<List<Json>>>();

  Future<void> _invite() async {
    final TextEditingController name = TextEditingController();
    String role = 'agent';
    final bool owner = sessionOf(context).role == 'owner';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => StatefulBuilder(
        builder: (BuildContext c, StateSetter set) => AlertDialog(
          title: const Text('Invite team member'),
          content: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
            const SizedBox(height: 8),
            RadioListTile<String>(value: 'agent', groupValue: role, onChanged: (String? v) => set(() => role = v!), title: const Text('Agent'), subtitle: const Text('Inbox and customers')),
            if (owner) RadioListTile<String>(value: 'admin', groupValue: role, onChanged: (String? v) => set(() => role = v!), title: const Text('Admin'), subtitle: const Text('Also workflows, FAQs, team')),
          ]),
          actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Create invite'))],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final Json r = await apiOf(context).post('/team', <String, dynamic>{'name': name.text, 'role': role});
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext c) => AlertDialog(
          title: const Text('Invite code'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('Send this to ${name.text}. In AUTOMETA they open Business mode, enter ${sessionOf(context).serverUrl} and this code:'),
            const SizedBox(height: 12),
            SelectableText(str(r['inviteCode']), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontFamily: 'monospace')),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: str(r['inviteCode']))), child: const Text('Copy')),
            FilledButton(onPressed: () => Navigator.pop(c), child: const Text('Done')),
          ],
        ),
      );
      await _key.currentState?.reload();
    } catch (e) {
      if (mounted) await showBusinessError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool canEdit = sessionOf(context).allowed('team.write');
    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      floatingActionButton: canEdit ? FloatingActionButton.extended(onPressed: _invite, icon: const Icon(Icons.person_add_alt), label: const Text('Invite')) : null,
      body: Loader<List<Json>>(
        key: _key,
        load: () => apiOf(context).list('/team'),
        builder: (BuildContext context, List<Json> team, Future<void> Function() reload) => ListView(
          children: <Widget>[
            for (final Json m in team)
              ListTile(
                leading: CircleAvatar(child: Text(str(m['name']).isEmpty ? '?' : str(m['name']).characters.first.toUpperCase())),
                title: Text(str(m['name'])),
                subtitle: Text('${str(m['role'])}${m['active'] == true ? '' : ' · removed'}${m['joined'] == true ? '' : ' · invite pending'}'),
                trailing: canEdit && m['role'] != 'owner' && m['active'] == true
                    ? IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () async {
                          try {
                            await apiOf(context).patch('/team/${m['id']}', <String, dynamic>{'active': false});
                            await reload();
                          } catch (e) {
                            if (context.mounted) await showBusinessError(context, e);
                          }
                        },
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}

class AuditScreen extends StatelessWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Audit log')),
        body: Loader<List<Json>>(
          load: () => apiOf(context).list('/audit'),
          builder: (BuildContext context, List<Json> rows, _) => ListView(children: <Widget>[
            for (final Json r in rows)
              ListTile(
                dense: true,
                title: Text('${str(r['member'])} · ${str(r['action'])}'),
                subtitle: Text(r['detail'] == null ? str(r['target']) : '${str(r['target'])} ${r['detail']}'),
                trailing: Text(ago(r['ts'])),
              ),
          ]),
        ),
      );
}
