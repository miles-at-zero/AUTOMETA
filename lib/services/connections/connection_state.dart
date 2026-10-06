import 'package:flutter/foundation.dart';

/// Connection lifecycle states (spec §4, §30, §40).
///
/// `connected` is only ever reported after the integration has verified it can
/// actually act — a stored token is not proof of a working connection.
enum ConnectionStatus {
  notConnected('not_connected', 'Not connected'),
  needsConfiguration('needs_configuration', 'Needs configuration'),
  pendingVerification('pending_verification', 'Pending verification'),
  connected('connected', 'Connected'),
  degraded('degraded', 'Connected with limits'),
  error('error', 'Connection error'),
  unavailable('unavailable', 'Not available');

  const ConnectionStatus(this.wire, this.label);

  final String wire;
  final String label;

  bool get isUsable => this == connected || this == degraded;

  static ConnectionStatus fromWire(Object? value, {ConnectionStatus fallback = notConnected}) {
    final String raw = '$value'.toLowerCase().trim();
    for (final ConnectionStatus status in ConnectionStatus.values) {
      if (status.wire == raw || status.name.toLowerCase() == raw) return status;
    }
    return fallback;
  }
}

/// A snapshot of one integration's real, verified state.
@immutable
class ConnectionRecord {
  const ConnectionRecord({
    required this.service,
    required this.status,
    this.accountType,
    this.label = '',
    this.capabilities = const <String>[],
    this.limitations = const <String>[],
    this.metadata = const <String, String>{},
    this.connectedAt,
    this.updatedAt,
  });

  final String service;
  final ConnectionStatus status;

  /// e.g. `personal` / `business` for WhatsApp.
  final String? accountType;

  /// Short human line, e.g. "Personal account".
  final String label;

  /// Only things that actually work right now.
  final List<String> capabilities;

  /// Honest statements about what this connection cannot do.
  final List<String> limitations;

  final Map<String, String> metadata;
  final DateTime? connectedAt;
  final DateTime? updatedAt;

  bool get isUsable => status.isUsable;

  ConnectionRecord copyWith({
    ConnectionStatus? status,
    String? accountType,
    String? label,
    List<String>? capabilities,
    List<String>? limitations,
    Map<String, String>? metadata,
    DateTime? connectedAt,
    DateTime? updatedAt,
  }) =>
      ConnectionRecord(
        service: service,
        status: status ?? this.status,
        accountType: accountType ?? this.accountType,
        label: label ?? this.label,
        capabilities: capabilities ?? this.capabilities,
        limitations: limitations ?? this.limitations,
        metadata: metadata ?? this.metadata,
        connectedAt: connectedAt ?? this.connectedAt,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'service': service,
        'status': status.wire,
        if (accountType != null) 'account_type': accountType,
        'label': label,
        'capabilities': capabilities,
        'limitations': limitations,
        'metadata': metadata,
      };
}
