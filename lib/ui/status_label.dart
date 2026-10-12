import '../domain/models/execution.dart';
import '../domain/models/execution_status.dart';
import '../domain/models/step.dart';

/// Status text that never claims more than the app knows (spec §40).
///
/// Lives on its own so every screen — Activity, Automations, History,
/// Approvals, the Control Room — reports an outcome with exactly the same
/// words. The old Home screen used to own it; that screen is now the Control
/// Room, and this is the part the other screens still need.
String honestStatusLabel(ExecutionRecord r) {
  if (r.dryRun) return 'SIMULATION';
  if (r.status == ExecutionStatus.success &&
      r.stepResults.any((StepExecution s) => s.code == 'whatsapp.handed_to_user')) {
    return 'Handed to WhatsApp — you tap Send';
  }
  if (r.status == ExecutionStatus.waitingApproval) return 'WAITING FOR APPROVAL';
  return r.status.label;
}
