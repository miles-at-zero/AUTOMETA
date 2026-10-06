/// Base type for every expected, user-explainable failure inside AUTOMETA.
///
/// Anything that reaches the UI as an error string should originate here so
/// the message is written for a human, not lifted from a stack trace.
class AutometaException implements Exception {
  const AutometaException(this.message, {this.code, this.cause, this.retriable = false});

  final String message;
  final String? code;
  final Object? cause;
  final bool retriable;

  @override
  String toString() => 'AutometaException(${code ?? 'error'}): $message';
}

/// A workflow definition that cannot be executed as written.
class WorkflowValidationException extends AutometaException {
  const WorkflowValidationException(super.message, {super.code = 'workflow.invalid'});
}

/// The engine refused to run (paused, missing connection, approval timeout…).
class EngineRefusedException extends AutometaException {
  const EngineRefusedException(super.message, {super.code = 'engine.refused'});
}

/// A secret could not be read from secure storage.
class SecretUnavailableException extends AutometaException {
  const SecretUnavailableException(super.message, {super.code = 'secret.unavailable'});
}

/// An integration is present in code but cannot operate right now.
class IntegrationUnavailableException extends AutometaException {
  const IntegrationUnavailableException(super.message, {super.code = 'integration.unavailable'});
}
