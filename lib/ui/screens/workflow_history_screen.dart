import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_services.dart';
import '../../core/theme/design_tokens.dart';
import '../../core/utils/formatters.dart';
import '../../domain/models/execution.dart';
import '../../domain/models/workflow.dart';
import '../widgets/autometa_widgets.dart';
import 'execution_detail_screen.dart';
import 'home_screen.dart';

class WorkflowHistoryScreen extends StatelessWidget {
  const WorkflowHistoryScreen({required this.workflow, super.key});
  final Workflow workflow;

  @override
  Widget build(BuildContext context) {
    final AppServices services = context.read<AppServices>();
    return Scaffold(
      appBar: AppBar(title: Text(workflow.name)),
      body: FutureBuilder<List<ExecutionRecord>>(
        future: services.executions.forWorkflow(workflow.id),
        builder: (BuildContext context, AsyncSnapshot<List<ExecutionRecord>> snap) {
          final List<ExecutionRecord> items = snap.data ?? <ExecutionRecord>[];
          if (snap.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
          if (items.isEmpty) {
            return const EmptyState(icon: Icons.history, title: 'No runs yet', message: 'This automation has not run.');
          }
          return ListView(
            padding: EdgeInsets.all(AutometaSpacing.page(context)),
            children: <Widget>[
              for (final ExecutionRecord r in items)
                ListTile(
                  leading: StatusDot(statusColor(r.status)),
                  title: Text(honestStatusLabel(r)),
                  subtitle: Text(Formatters.stamp(r.scheduledFor.toLocal())),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ExecutionDetailScreen(record: r))),
                ),
            ],
          );
        },
      ),
    );
  }
}
