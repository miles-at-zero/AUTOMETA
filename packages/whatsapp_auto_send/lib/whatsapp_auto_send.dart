import 'package:flutter/services.dart';

/// Result of an auto-send attempt. Only [AutoSendStatus.sent] means WhatsApp
/// accepted the message (the Send tap happened and the input box cleared).
enum AutoSendStatus { sent, unconfirmed, locked, disabled, busy, failed }

class AutoSendResult {
  const AutoSendResult(this.status, [this.reason]);
  final AutoSendStatus status;
  final String? reason;
}

class AutoSendServiceStatus {
  const AutoSendServiceStatus({required this.enabled, required this.running, this.whatsappPackage});
  final bool enabled;
  final bool running;
  final String? whatsappPackage;
  bool get ready => enabled && running && whatsappPackage != null;
}

/// Dart side of the on-device WhatsApp auto-send Accessibility Service.
class WhatsAppAutoSend {
  const WhatsAppAutoSend();

  static const MethodChannel _channel = MethodChannel('dev.autometa/whatsapp_auto_send');

  Future<AutoSendServiceStatus> status() async {
    try {
      final Map<dynamic, dynamic>? m = await _channel.invokeMapMethod<dynamic, dynamic>('status');
      return AutoSendServiceStatus(
        enabled: m?['enabled'] == true,
        running: m?['running'] == true,
        whatsappPackage: m?['whatsappPackage'] as String?,
      );
    } on MissingPluginException {
      return const AutoSendServiceStatus(enabled: false, running: false);
    }
  }

  Future<void> openSettings() => _channel.invokeMethod<void>('openSettings');

  Future<AutoSendResult> send({required String phoneDigits, required String text}) async {
    try {
      final Map<dynamic, dynamic>? m = await _channel.invokeMapMethod<dynamic, dynamic>(
        'send',
        <String, String>{'phone': phoneDigits, 'text': text},
      );
      final String raw = '${m?['status']}';
      final AutoSendStatus status = AutoSendStatus.values.firstWhere(
        (AutoSendStatus s) => s.name == raw,
        orElse: () => AutoSendStatus.failed,
      );
      return AutoSendResult(status, m?['reason'] as String?);
    } on MissingPluginException {
      return const AutoSendResult(AutoSendStatus.disabled, 'Auto-send is only available on Android');
    } on PlatformException catch (e) {
      return AutoSendResult(AutoSendStatus.failed, e.message);
    }
  }
}
