import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../widgets/autometa_widgets.dart';
import 'cloud_account_screen.dart';
import 'cloud_execution_screen.dart';

String _when(Object? ms) {
  final int? v = ms is num ? ms.toInt() : int.tryParse('${ms ?? ''}');
  return v == null || v == 0 ? 'never' : Formatters.relative(DateTime.fromMillisecondsSinceEpoch(v));
}

/// Incoming webhooks owned by the signed-in Autometa Cloud workspace.
/// Webhooks are created when an automation with a Webhook trigger is synced
/// to Cloud; this screen lists them and opens their management page.
class WebhooksScreen extends StatefulWidget {
  const WebhooksScreen({super.key});

  @override
  State<WebhooksScreen> createState() => _WebhooksScreenState();
}

class _WebhooksScreenState extends State<WebhooksScreen> {
  List<Json>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final CloudSession cloud = context.read<CloudSession>();
    if (!cloud.signedIn) return;
    try {
      final List<Json> items = await cloud.webhooks();
      if (mounted) setState(() {
        _items = items;
        _error = null;
      });
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CloudSession cloud = context.watch<CloudSession>();
    final List<Json>? items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('WEBHOOKS')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.all(AutometaSpacing.page(context)),
          children: <Widget>[
            if (!cloud.signedIn)
              EmptyState(
                icon: Icons.cloud_off_outlined,
                title: 'Sign in to Autometa Cloud',
                message: 'Webhooks are received by Autometa Cloud. A phone cannot receive webhooks.',
                action: PrimaryAction(
                  label: 'Cloud account',
                  icon: Icons.cloud_outlined,
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen())),
                ),
              )
            else if (_error != null)
              EmptyState(icon: Icons.error_outline, title: 'Could not load webhooks', message: _error!)
            else if (items == null)
              const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
            else if (items.isEmpty)
              const EmptyState(
                icon: Icons.webhook_outlined,
                title: 'No webhooks yet',
                message: 'Create an automation with the "Webhook received" trigger and Cloud execution. '
                    'Autometa Cloud creates its webhook URL and secret when you save it.',
              )
            else
              for (final Json w in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute<void>(
                          builder: (_) => WebhookDetailScreen(webhookId: str(w['id']))));
                      await _load();
                    },
                    child: Row(children: <Widget>[
                      StatusDot(w['enabled'] == true ? AutometaColors.success : AutometaColors.neutral),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                          Text(str(w['name']).isEmpty ? 'Webhook' : str(w['name']),
                              style: Theme.of(context).textTheme.titleMedium),
                          Text('${w['enabled'] == true ? 'Enabled' : 'Disabled'} · '
                              '${w['requestCount'] ?? 0} requests · last ${_when(w['lastReceivedAt'])}',
                              style: Theme.of(context).textTheme.bodySmall),
                        ]),
                      ),
                      const Icon(Icons.chevron_right),
                    ]),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

/// One webhook: URL, enable/disable, rotate secret or URL, send a test
/// request, linked automations and the recent request history.
class WebhookDetailScreen extends StatefulWidget {
  const WebhookDetailScreen({required this.webhookId, super.key});

  final String webhookId;

  @override
  State<WebhookDetailScreen> createState() => _WebhookDetailScreenState();
}

class _WebhookDetailScreenState extends State<WebhookDetailScreen> {
  Json? _w;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Json w = await context.read<CloudSession>().webhook(widget.webhookId);
      if (mounted) setState(() {
        _w = w;
        _error = null;
      });
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _do(Future<void> Function(CloudSession c) f) async {
    setState(() => _busy = true);
    try {
      await f(context.read<CloudSession>());
      await _load();
    } on CloudException catch (e) {
      if (mounted) showToast(context, e.message, color: AutometaColors.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) showToast(context, '$label copied');
  }

  Future<void> _rotateSecret() async {
    final bool ok = await confirmDialog(context,
        title: 'Generate a new secret?',
        message: 'The current secret stops working immediately. Senders must be updated with the new one.',
        confirmLabel: 'Generate',
        destructive: true);
    if (!ok || !mounted) return;
    await _do((CloudSession c) async {
      final Json r = await c.rotateWebhookSecret(widget.webhookId);
      final String secret = str(r['secret']);
      if (!mounted || secret.isEmpty) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext d) => AlertDialog(
          title: const Text('New webhook secret'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('Copy it now. It is shown only once. Send it in the X-Autometa-Secret header.'),
            const SizedBox(height: 12),
            SelectableText(secret, style: const TextStyle(fontFamily: 'monospace')),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => _copy('Secret', secret), child: const Text('Copy')),
            FilledButton(onPressed: () => Navigator.of(d).pop(), child: const Text('Done')),
          ],
        ),
      );
    });
  }

  Future<void> _rotateUrl() async {
    final bool ok = await confirmDialog(context,
        title: 'Regenerate URL?',
        message: 'The current URL stops working immediately. Anything sending to it must be updated.',
        confirmLabel: 'Regenerate',
        destructive: true);
    if (ok && mounted) await _do((CloudSession c) => c.rotateWebhookUrl(widget.webhookId));
  }

  Future<void> _test() => _do((CloudSession c) async {
        final Json r = await c.testWebhook(widget.webhookId);
        if (mounted) showToast(context, 'Test request: ${str(r['outcome'])}');
      });

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final Json? w = _w;
    final List<Json> autos = asList(w?['automations']);
    final List<Json> reqs = asList(w?['requests']);
    return Scaffold(
      appBar: AppBar(title: Text(w == null ? 'Webhook' : str(w['name']))),
      body: _error != null
          ? EmptyState(icon: Icons.error_outline, title: 'Could not load webhook', message: _error!)
          : w == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: EdgeInsets.all(AutometaSpacing.page(context)), children: <Widget>[
                    if (_busy) const LinearProgressIndicator(),
                    Panel(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                        const SectionLabel('URL'),
                        SelectableText(str(w['url']), style: const TextStyle(fontFamily: 'monospace')),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: <Widget>[
                          OutlinedButton.icon(
                              onPressed: () => _copy('URL', str(w['url'])), icon: const Icon(Icons.copy, size: 18), label: const Text('Copy URL')),
                          OutlinedButton.icon(
                              onPressed: _busy ? null : _rotateUrl, icon: const Icon(Icons.refresh, size: 18), label: const Text('Regenerate URL')),
                        ]),
                        const SizedBox(height: 8),
                        Text(w['requiresSecret'] == true
                            ? 'Requests must include the secret (X-Autometa-Secret header).'
                            : 'No secret: anyone with the URL can trigger it. Generate a secret to protect it.',
                            style: t.bodySmall),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    Panel(
                      child: Column(children: <Widget>[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Enabled'),
                          subtitle: const Text('Disabled webhooks reject requests and start nothing.'),
                          value: w['enabled'] == true,
                          onChanged: _busy ? null : (bool v) => _do((CloudSession c) => c.setWebhookEnabled(widget.webhookId, v)),
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.key_outlined),
                          title: Text(w['requiresSecret'] == true ? 'Generate new secret' : 'Generate secret'),
                          onTap: _busy ? null : _rotateSecret,
                        ),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.science_outlined),
                          title: const Text('Send test request'),
                          subtitle: const Text('Sample payload, marked as a test in history.'),
                          onTap: _busy ? null : _test,
                        ),
                      ]),
                    ),
                    const SizedBox(height: 16),
                    SectionLabel('AUTOMATIONS (${autos.length})'),
                    if (autos.isEmpty) Text('No automation uses this webhook.', style: t.bodySmall),
                    for (final Json a in autos) Text('• ${str(a['name'])} (${str(a['status'])})'),
                    const SizedBox(height: 16),
                    SectionLabel('RECENT REQUESTS (${reqs.length})'),
                    if (reqs.isEmpty) Text('No requests received yet.', style: t.bodySmall),
                    for (final Json r in reqs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: StatusDot(((r['status'] as num?) ?? 0) < 300 ? AutometaColors.success : AutometaColors.danger),
                        title: Text('${r['status']} · ${str(r['outcome'])}'),
                        subtitle: Text('${_when(r['receivedAt'])}${r['isTest'] == 1 || r['isTest'] == true ? ' · test' : ''}'),
                        trailing: str(r['executionId']).isEmpty ? null : const Icon(Icons.chevron_right),
                        onTap: str(r['executionId']).isEmpty
                            ? null
                            : () => Navigator.of(context).push(MaterialPageRoute<void>(
                                builder: (_) => CloudExecutionScreen(executionId: str(r['executionId'])))),
                      ),
                  ]),
                ),
    );
  }
}
