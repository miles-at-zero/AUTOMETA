import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../business/business_api.dart';
import '../../cloud/cloud_session.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../widgets/autometa_widgets.dart';
import 'cloud_account_screen.dart';

/// One Autometa Cloud execution, read from `/v1/executions/:id`: every step
/// with its status, detail (conditions show ✓/✕ per rule), error and fix.
/// Offers Retry for failed runs and Reconnect when a connection broke.
/// Push/in-app notifications deep-link here with the execution id.
class CloudExecutionScreen extends StatefulWidget {
  const CloudExecutionScreen({required this.executionId, super.key});

  final String executionId;

  @override
  State<CloudExecutionScreen> createState() => _CloudExecutionScreenState();
}

class _CloudExecutionScreenState extends State<CloudExecutionScreen> {
  Json? _e;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final Json e = await context.read<CloudSession>().execution(widget.executionId);
      if (mounted) setState(() {
        _e = e;
        _error = null;
      });
    } on CloudException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      final Json r = await context.read<CloudSession>().retryExecution(widget.executionId);
      if (!mounted) return;
      showToast(context, 'Retried: ${str(r['status'])}');
      if (str(r['id']).isNotEmpty && r['id'] != widget.executionId) {
        await Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(builder: (_) => CloudExecutionScreen(executionId: str(r['id']))));
        return;
      }
      await _load();
    } on CloudException catch (e) {
      if (mounted) showToast(context, e.message, color: AutometaColors.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Color colorFor(String s) => switch (s) {
        'success' => AutometaColors.success,
        'running' || 'waiting' => AutometaColors.accent,
        'failed' || 'partial' => AutometaColors.danger,
        'simulated' => AutometaColors.secondary,
        'stopped' => AutometaColors.warning,
        _ => AutometaColors.neutral,
      };

  static String labelFor(String s) => switch (s) {
        'success' => 'Success',
        'running' => 'Running',
        'waiting' => 'Waiting',
        'failed' => 'Failed',
        'partial' => 'Partly done',
        'skipped' => 'Skipped',
        'stopped' => 'Stopped here (condition not met)',
        'simulated' => 'Simulated (test)',
        'cancelled' => 'Cancelled',
        _ => s,
      };

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final Json? e = _e;
    return Scaffold(
      appBar: AppBar(title: Text(e == null ? 'Cloud run' : '☁️ ${str(e['automationName'])} #${str(e['number'])}')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.all(AutometaSpacing.page(context)),
          children: <Widget>[
            if (_error != null) Panel(child: Text(_error!)),
            if (e == null && _error == null) const LinearProgressIndicator(),
            if (e != null) ...<Widget>[
              Panel(
                glow: colorFor(str(e['status'])),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Row(children: <Widget>[
                    StatusDot(colorFor(str(e['status']))),
                    const SizedBox(width: 8),
                    Expanded(child: Text(labelFor(str(e['status'])), style: t.titleMedium)),
                    const StatusPill(label: '☁️ Cloud', color: AutometaColors.accent),
                  ]),
                  const SizedBox(height: 8),
                  LabeledValue(label: 'Started', value: Formatters.stamp(DateTime.fromMillisecondsSinceEpoch(intOf(e['startedAt'])))),
                  if (e['durationMs'] != null) LabeledValue(label: 'Took', value: '${(intOf(e['durationMs']) / 1000).toStringAsFixed(1)} s'),
                  LabeledValue(label: 'Trigger', value: str(e['triggerType'])),
                  if (intOf(e['retryCount']) > 0) LabeledValue(label: 'Retries', value: str(e['retryCount'])),
                  if (e['notice'] != null) Text(str(e['notice']), style: t.bodySmall),
                  if (e['error'] != null) Text(str(e['error']), style: t.bodyMedium?.copyWith(color: AutometaColors.danger)),
                ]),
              ),
              const SizedBox(height: AutometaSpacing.lg),
              Text('STEPS', style: t.labelLarge?.copyWith(letterSpacing: 1.2)),
              const SizedBox(height: 8),
              for (final Json s in asList(e['steps']))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    accentLeft: true,
                    borderColor: colorFor(str(s['status'])),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                      Row(children: <Widget>[
                        Expanded(child: Text(str(s['label']).isEmpty ? str(s['kind']) : str(s['label']), style: t.titleSmall)),
                        Text(labelFor(str(s['status'])), style: t.labelMedium?.copyWith(color: colorFor(str(s['status'])))),
                      ]),
                      if (str(s['detail']).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(str(s['detail']))),
                      if (str(s['error']).isNotEmpty)
                        Padding(padding: const EdgeInsets.only(top: 4), child: Text(str(s['error']), style: t.bodyMedium?.copyWith(color: AutometaColors.danger))),
                      if (str(s['fix']).isNotEmpty)
                        Padding(padding: const EdgeInsets.only(top: 4), child: Text('How to fix: ${str(s['fix'])}', style: t.bodySmall)),
                      if (intOf(s['attempts']) > 1) Text('${intOf(s['attempts'])} attempts', style: t.bodySmall),
                    ]),
                  ),
                ),
              const SizedBox(height: AutometaSpacing.lg),
              if (asMap(e['actions'])['reconnect'] != null)
                PrimaryAction(
                  label: 'Reconnect ${str(asMap(asMap(e['actions'])['reconnect'])['integration'])}',
                  icon: Icons.link,
                  onPressed: () async {
                    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const CloudAccountScreen()));
                    await _load();
                  },
                ),
              if (asMap(e['actions'])['canRetry'] == true) ...<Widget>[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _retry,
                  icon: const Icon(Icons.replay),
                  label: const Text('Retry this run'),
                ),
                Text('Steps that already succeeded are not repeated.', style: t.bodySmall),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
