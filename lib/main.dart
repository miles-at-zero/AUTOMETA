import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'cloud/cloud_session.dart';
import 'core/utils/logger.dart';
import 'services/connections/connection_manager.dart';
import 'services/settings/settings_service.dart';
import 'state/app_state.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final Logger log = Logger.withTag('MAIN');

  final AppServices services = await AppServices.bootstrap();
  await services.notifications.initialize();

  final AppState state = AppState(services: services);
  // Cloud automations are run by the backend; this session only lets the app
  // configure and monitor them. Offline start keeps the token and cached state.
  final CloudSession cloud = CloudSession(services);
  state.cloud = cloud;
  unawaited(cloud.init().then((_) => cloud.checkAlerts()));
  await state.refresh();

  // Re-arm on every launch: covers app updates, force-stops and anything the
  // OS dropped. Catch-up then fills gaps honestly (run or SKIP).
  unawaited(() async {
    try {
      await services.execution.expireStaleApprovals();
      await services.execution.catchUpMissedRuns();
      await services.scheduler.syncAll();
      await services.connections.refreshAll();
      await state.refresh();
    } catch (error, stack) {
      log.error('Startup sync failed', error, stack);
    }
  }());

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: state),
        ChangeNotifierProvider<CloudSession>.value(value: cloud),
        ChangeNotifierProvider<SettingsService>.value(value: services.settings),
        ChangeNotifierProvider<ConnectionManager>.value(value: services.connections),
      ],
      child: AutometaApp(services: services),
    ),
  );
}
