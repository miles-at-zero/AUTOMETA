package dev.autometa.wa

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Registered in every Flutter engine, including the background alarm isolate. */
class WhatsAppAutoSendPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "dev.autometa/whatsapp_auto_send").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> result.success(
                        mapOf(
                            "enabled" to isEnabled(),
                            "running" to (AutoSendAccessibilityService.instance != null),
                            "whatsappPackage" to whatsappPackage(),
                        )
                    )
                    "openSettings" -> {
                        context.startActivity(
                            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    "send" -> {
                        val phone = call.argument<String>("phone").orEmpty().filter { it.isDigit() }
                        val text = call.argument<String>("text").orEmpty()
                        val pkg = call.argument<String>("package") ?: whatsappPackage()
                        val service = AutoSendAccessibilityService.instance
                        when {
                            pkg == null -> result.success(mapOf("status" to "failed", "reason" to "WhatsApp is not installed"))
                            phone.isEmpty() || text.isEmpty() -> result.success(mapOf("status" to "failed", "reason" to "Missing phone number or message"))
                            service == null -> result.success(mapOf("status" to "disabled", "reason" to "Auto-send is off. Turn it on in AUTOMETA → Connections → WhatsApp"))
                            else -> {
                                var replied = false
                                service.send(phone, text, pkg) { outcome ->
                                    if (!replied) { replied = true; result.success(outcome) }
                                }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    private fun isEnabled(): Boolean {
        val flat = Settings.Secure.getString(context.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = ComponentName(context, AutoSendAccessibilityService::class.java)
        return flat.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    private fun whatsappPackage(): String? = listOf("com.whatsapp", "com.whatsapp.w4b").firstOrNull { installed(it) }

    private fun installed(pkg: String): Boolean = try {
        if (Build.VERSION.SDK_INT >= 33) {
            context.packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION") context.packageManager.getPackageInfo(pkg, 0)
        }
        true
    } catch (e: PackageManager.NameNotFoundException) { false }
}
