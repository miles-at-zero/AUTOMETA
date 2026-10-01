import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../business/business_api.dart';
import '../../../business/business_session.dart';
import '../../../core/theme/design_tokens.dart';
import 'plans_screen.dart';

BusinessSession sessionOf(BuildContext context) => context.read<BusinessSession>();
BusinessApi apiOf(BuildContext context) => context.read<BusinessSession>().api!;

/// Shows a server error; plan errors offer an upgrade instead of a dead end.
Future<void> showBusinessError(BuildContext context, Object error) async {
  if (!context.mounted) return;
  if (error is BusinessApiException && error.isUpgrade) {
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        icon: const Icon(Icons.workspace_premium_outlined, color: AutometaColors.secondary),
        title: const Text('Upgrade needed'),
        content: Text(error.message),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('See plans')),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PlansScreen()));
    }
    return;
  }
  final String extra = error is BusinessApiException && error.errors.length > 1 ? '\n• ${error.errors.skip(1).join('\n• ')}' : '';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error$extra'), behavior: SnackBarBehavior.floating));
}

void toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}

/// Loads a value from the server with loading / error / retry states.
class Loader<T> extends StatefulWidget {
  const Loader({required this.load, required this.builder, super.key});

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload) builder;

  @override
  State<Loader<T>> createState() => LoaderState<T>();
}

class LoaderState<T> extends State<Loader<T>> {
  T? _data;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => _loading = _data == null);
    try {
      final T d = await widget.load();
      if (mounted) setState(() { _data = d; _error = null; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final T? d = _data;
    if (d == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.cloud_off_outlined, size: 40, color: AutometaColors.warning),
              const SizedBox(height: 12),
              Text('$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: reload, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(onRefresh: reload, child: widget.builder(context, d, reload));
  }
}

String ago(Object? ms) {
  final int t = intOf(ms);
  if (t == 0) return '';
  final Duration d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(t));
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  final DateTime x = DateTime.fromMillisecondsSinceEpoch(t);
  return '${x.day}/${x.month}';
}

String naira(Object? v) {
  final String s = intOf(v).toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (Match m) => '${m[1]},');
  return '₦$s';
}

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = '', int lines = 1}) {
  final TextEditingController c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, minLines: lines, maxLines: lines == 1 ? 1 : 8, decoration: InputDecoration(hintText: hint)),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('OK')),
      ],
    ),
  );
}
