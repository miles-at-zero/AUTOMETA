import 'package:flutter/foundation.dart';

import '../../core/constants/app_constants.dart';
import '../../core/utils/logger.dart';
import '../../data/repositories/connection_repository.dart';
import '../integrations/integration.dart';
import 'connection_state.dart';

/// The Connections page's data source (spec §30).
///
/// Every card is rendered from a [ConnectionRecord] that came from a real
/// `check()` call. Nothing is marked connected on the strength of stored
/// settings alone, and services AUTOMETA cannot implement yet are listed
/// separately as planned, never as broken or half-working.
class ConnectionManager extends ChangeNotifier {
  ConnectionManager({required this.registry, required this.repository});

  final IntegrationRegistry registry;
  final ConnectionRepository repository;

  final Logger _log = Logger.withTag('CONN');
  final Map<String, ConnectionRecord> _records = <String, ConnectionRecord>{};
  bool _busy = false;

  bool get isRefreshing => _busy;

  List<ConnectionRecord> get records {
    final List<ConnectionRecord> list = _records.values.toList()
      ..sort((ConnectionRecord a, ConnectionRecord b) {
        final int byUsable = (b.isUsable ? 1 : 0) - (a.isUsable ? 1 : 0);
        if (byUsable != 0) return byUsable;
        return a.service.compareTo(b.service);
      });
    return list;
  }

  ConnectionRecord? recordFor(String service) => _records[service];

  /// Services listed as "coming soon" with no implementation behind them.
  List<PlannedIntegration> get planned => IntegrationRegistry.planned;

  /// Loads stored metadata first (instant paint) then verifies each one.
  Future<void> refreshAll() async {
    _busy = true;
    notifyListeners();
    try {
      for (final ConnectionRecord stored in await repository.all()) {
        _records[stored.service] = stored;
      }
      for (final Integration integration in registry.all) {
        await refresh(integration.id);
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Verifies one integration and persists the result.
  Future<ConnectionRecord?> refresh(String serviceId) async {
    final Integration? integration = registry.byId(serviceId);
    if (integration == null) return null;

    final ConnectionRecord? stored = await repository.byService(serviceId);
    final IntegrationAvailability availability;
    try {
      availability = await integration.check();
    } catch (error) {
      _log.warn('Verification failed for $serviceId', error);
      final ConnectionRecord failed = (stored ??
              ConnectionRecord(
                service: serviceId,
                status: ConnectionStatus.error,
              ))
          .copyWith(
        status: ConnectionStatus.error,
        label: integration.displayName,
        limitations: <String>['Verification failed: $error'],
      );
      _records[serviceId] = failed;
      await repository.save(failed);
      notifyListeners();
      return failed;
    }

    final ConnectionRecord record = availability.toRecord(
      serviceId,
      connectedAt: availability.status.isUsable
          ? (stored?.connectedAt ?? DateTime.now())
          : null,
    );
    _records[serviceId] = record;
    await repository.save(record);
    _log.info('$serviceId -> ${record.status.wire} (${record.capabilities.length} capabilities)');
    notifyListeners();
    return record;
  }

  Future<void> disconnect(String serviceId) async {
    final Integration? integration = registry.byId(serviceId);
    if (integration == null) return;
    await integration.disconnect();
    await repository.delete(serviceId);
    _records.remove(serviceId);
    notifyListeners();
  }

  /// True when the given integration can act right now. Used by the executor
  /// layer to fail fast with an honest reason.
  bool isUsable(String serviceId) => _records[serviceId]?.isUsable ?? false;

  /// Convenience for the dashboard chip row.
  ConnectionRecord? get whatsapp => _records[IntegrationIds.whatsapp];
  ConnectionRecord? get ai => _records[IntegrationIds.ai];
}
