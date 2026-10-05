import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../cloud/push_client.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../widgets/autometa_widgets.dart';

/// Autometa Cloud account: sign in / sign up / reset, and the Cloud
/// connections (credentials live encrypted on the server, used by Cloud runs).
class CloudAccountScreen extends StatefulWidget {
  const CloudAccountScreen({super.key});

  @override
  State<CloudAccountScreen> createState() => _CloudAccountScreenState();
}

class _CloudAccountScreenState extends State<CloudAccountScreen> {
  late final TextEditingController _url = TextEditingController(
      text: context.read<CloudSession>().serverUrl.isEmpty ? CloudSession.defaultServerUrl : context.read<CloudSession>().serverUrl);
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _signUp = false;
  bool _busy = false;
  String? _error;
  List<Json>? _integrations;
  List<Json>? _connections;

  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: () {
      if (_awaitingOAuth) {
        _awaitingOAuth = false;
        _loadConnections();
      }
    });
    if (context.read<CloudSession>().signedIn) _loadConnections();
  }

  @override
  void dispose() {
    _life.dispose();
    _url.dispose();
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on BusinessApiException catch (e) {
      _error = e.message;
    } on CloudException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() => _run(() async {
        final CloudSession s = context.read<CloudSession>();
        if (_url.text.trim().isEmpty) throw CloudException('Enter your Autometa Cloud server address.');
        if (_signUp) {
          await s.signUp(_url.text, _email.text, _password.text, _name.text);
        } else {
          await s.signIn(_url.text, _email.text, _password.text);
        }
        _password.clear();
        await _loadConnections();
      });

  Future<void> _forgot() => _run(() async {
        final String msg = await context.read<CloudSession>().forgotPassword(_url.text, _email.text);
        if (mounted) showToast(context, msg);
      });

  Future<void> _loadConnections() async {
    final CloudSession s = context.read<CloudSession>();
    try {
      final List<Json> i = await s.integrations();
      final List<Json> c = await s.connections();
      if (mounted) setState(() {
        _integrations = i;
        _connections = c;
      });
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool _awaitingOAuth = false;

  /// Google sign-in happens in the browser; the server stores the tokens.
  /// When the user comes back we reload the connection list (no fake state).
  Future<void> _connectOAuth(Json integration, {String? reconnectId}) => _run(() async {
        final String url = await context.read<CloudSession>().startOAuth(str(integration['id']), connectionId: reconnectId);
        final bool opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        if (!opened) throw CloudException('Couldn\'t open the browser for Google sign-in.');
        _awaitingOAuth = true;
        if (mounted) showToast(context, 'Finish signing in with Google, then come back here.');
      });

  Future<void> _connect(Json integration, {String? reconnectId}) async {
    if (asMap(integration['auth'])['type'] == 'oauth') return _connectOAuth(integration, reconnectId: reconnectId);
    final List<Json> fields = asList(asMap(integration['auth'])['fields']);
    final Map<String, TextEditingController> ctl = <String, TextEditingController>{
      for (final Json f in fields) str(f['key']): TextEditingController(),
    };
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text('${reconnectId == null ? 'Connect' : 'Reconnect'} ${str(integration['name'])}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text('Stored encrypted on your Autometa Cloud server and used only by your Cloud automations.',
                style: Theme.of(c).textTheme.bodySmall),
            for (final Json f in fields)
              TextField(
                controller: ctl[str(f['key'])],
                obscureText: f['type'] == 'password',
                decoration: InputDecoration(labelText: str(f['label']), helperText: f['help'] == null ? null : str(f['help']), helperMaxLines: 3),
              ),
          ]),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Connect')),
        ],
      ),
    );
    final Map<String, String> values = ctl.map((String k, TextEditingController v) => MapEntry<String, String>(k, v.text.trim()));
    for (final TextEditingController t in ctl.values) {
      t.dispose();
    }
    if (ok != true || !mounted) return;
    await _run(() async {
      final CloudSession s = context.read<CloudSession>();
      if (reconnectId == null) {
        await s.connect(str(integration['id']), values);
      } else {
        await s.reconnect(reconnectId, values);
      }
      await _loadConnections();
      if (mounted) showToast(context, '${str(integration['name'])} connected to Cloud');
    });
  }

  @override
  Widget build(BuildContext context) {
    final CloudSession s = context.watch<CloudSession>();
    final TextTheme t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Autometa Cloud')),
      body: ListView(
        padding: EdgeInsets.all(AutometaSpacing.page(context)),
        children: <Widget>[
          ResponsiveWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
              Panel(
                glow: AutometaColors.accent,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Row(children: <Widget>[
                    const Icon(Icons.cloud_outlined, color: AutometaColors.accent),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Cloud execution', style: t.titleMedium)),
                    const StatusPill(label: 'Recommended', color: AutometaColors.accent, filled: true),
                  ]),
                  const SizedBox(height: 6),
                  const Text('Cloud automations run on the Autometa server, so they keep running when the app is closed '
                      'or your phone is off or offline. This app sets them up and shows their history.'),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.lg),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: t.bodyMedium?.copyWith(color: AutometaColors.danger)),
                ),
              if (!s.signedIn) ...<Widget>[
                TextField(controller: _url, keyboardType: TextInputType.url, decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://api.your-autometa.com')),
                if (_signUp) TextField(controller: _name, decoration: const InputDecoration(labelText: 'Your name')),
                TextField(controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const <String>[AutofillHints.email], decoration: const InputDecoration(labelText: 'Email')),
                TextField(controller: _password, obscureText: true, decoration: InputDecoration(labelText: 'Password', helperText: _signUp ? 'At least 10 characters' : null)),
                const SizedBox(height: AutometaSpacing.lg),
                PrimaryAction(label: _signUp ? 'Create account' : 'Sign in', icon: Icons.login, busy: _busy, onPressed: _submit),
                TextButton(onPressed: _busy ? null : () => setState(() => _signUp = !_signUp), child: Text(_signUp ? 'I already have an account' : 'Create a Cloud account')),
                if (!_signUp) TextButton(onPressed: _busy ? null : _forgot, child: const Text('Forgot password?')),
                const SizedBox(height: 8),
                Text('No account? On-device automations keep working without one.', style: t.bodySmall),
              ] else ...<Widget>[
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                    LabeledValue(label: 'Signed in as', value: s.email),
                    LabeledValue(label: 'Plan', value: s.planName.isEmpty ? '—' : s.planName),
                    LabeledValue(label: 'Server', value: s.serverUrl),
                    if (s.error != null) Text('Offline: showing the last known state. ${s.error}', style: t.bodySmall),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: () => context.read<CloudSession>().signOut(), child: const Text('Sign out')),
                  ]),
                ),
                const SizedBox(height: AutometaSpacing.lg),
                const _PushPanel(),
                const SizedBox(height: AutometaSpacing.lg),
                Text('CLOUD CONNECTIONS', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
                const SizedBox(height: 8),
                if (_integrations == null)
                  const LinearProgressIndicator()
                else
                  for (final Json i in _integrations!.where((Json i) => <String>['token', 'oauth'].contains(asMap(i['auth'])['type'])))
                    Builder(builder: (BuildContext context) {
                      final Json? conn = _connections?.cast<Json?>().firstWhere((Json? c) => c?['integration'] == i['id'], orElse: () => null);
                      final String status = conn == null ? 'Not connected' : str(conn['status']);
                      final bool healthy = status == 'connected';
                      final bool available = i['available'] != false;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Panel(
                          child: Row(children: <Widget>[
                            StatusDot(conn == null ? AutometaColors.neutral : (healthy ? AutometaColors.success : AutometaColors.warning)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                                Text(str(i['name']), style: t.titleSmall),
                                Text(conn == null ? str(i['description']) : '${str(conn['identity'])} · ${status.replaceAll('_', ' ')}',
                                    style: t.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                                if (!available)
                                  Text(str(i['unavailableReason']).isEmpty ? 'Unavailable: server configuration required.' : str(i['unavailableReason']),
                                      style: t.bodySmall?.copyWith(color: AutometaColors.warning), maxLines: 3, overflow: TextOverflow.ellipsis),
                              ]),
                            ),
                            TextButton(
                              onPressed: _busy || !available ? null : () => _connect(i, reconnectId: conn == null ? null : str(conn['id'])),
                              child: Text(conn == null ? 'Connect' : (healthy ? 'Update' : 'Reconnect')),
                            ),
                          ]),
                        ),
                      );
                    }),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}


/// Honest push state for this phone plus per-device alert preferences
/// (stored on the server with the device token).
class _PushPanel extends StatelessWidget {
  const _PushPanel();

  @override
  Widget build(BuildContext context) {
    PushClient? p;
    try {
      p = context.watch<PushClient>();
    } on ProviderNotFoundException {
      return const SizedBox.shrink();
    }
    final PushClient push = p;
    final TextTheme t = Theme.of(context).textTheme;
    final Color color = switch (push.status) {
      PushStatus.registered => AutometaColors.success,
      PushStatus.idle => AutometaColors.neutral,
      _ => AutometaColors.warning,
    };
    final bool canSetPrefs = push.status == PushStatus.registered || push.status == PushStatus.serverNotConfigured;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.notifications_active_outlined),
          const SizedBox(width: 8),
          Expanded(child: Text('Phone alerts', style: t.titleSmall)),
          Flexible(child: StatusPill(label: push.status.label, color: color)),
        ]),
        const SizedBox(height: 6),
        Text(push.status.explanation, style: t.bodySmall),
        if (canSetPrefs) ...<Widget>[
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Failures, pauses and reconnect requests'),
            value: push.prefs.failures,
            onChanged: (bool v) => push.setPrefs(push.prefs.copyWith(failures: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Plan usage limits'),
            value: push.prefs.account,
            onChanged: (bool v) => push.setPrefs(push.prefs.copyWith(account: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Messages from your automations'),
            value: push.prefs.messages,
            onChanged: (bool v) => push.setPrefs(push.prefs.copyWith(messages: v)),
          ),
        ],
      ]),
    );
  }
}
