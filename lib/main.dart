import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_services.dart';
import 'cloud/cloud_session.dart';
import 'cloud/firebase_push_transport.dart';
import 'cloud/push_client.dart';
import 'cloud/push_routing.dart';
import 'core/utils/logger.dart';
import 'services/connections/connection_manager.dart';
import 'services/notifications/notification_service.dart';
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

  // Notification taps can arrive before any screen exists (cold start), so
  // they are parked here until the app shell attaches.
  final PendingNavigation navigation = PendingNavigation();
  navigation.open(PushDestination.fromLocalPayload(await services.notifications.launchPayload()));
  final PushClient push = PushClient(
    transport: FirebasePushTransport(),
    navigation: navigation,
    readSetting: services.settings.repository.get,
    writeSetting: services.settings.repository.set,
    postLocal: ({required String title, required String body, required String payload, required int id}) =>
        services.notifications.show(title: title, body: body, channel: NotificationChannels.cloudAlerts, payload: payload, id: id),
  );
  cloud.push = push;
  await push.start(); // Reads the FCM tap that launched the app, if any.
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
        ChangeNotifierProvider<PushClient>.value(value: push),
        Provider<PendingNavigation>.value(value: navigation),
        ChangeNotifierProvider<SettingsService>.value(value: services.settings),
        ChangeNotifierProvider<ConnectionManager>.value(value: services.connections),
      ],
      child: AutometaApp(services: services),
    ),
  );
}
