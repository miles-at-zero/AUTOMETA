package dev.autometa.wa

import android.accessibilityservice.AccessibilityService
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Presses WhatsApp's Send button for a message AUTOMETA has just opened.
 *
 * Flow for one job:
 *  1. Open the chat via the official click-to-chat link, text prefilled.
 *  2. When the chat is on screen, check the input box holds OUR text, then
 *     click Send.
 *  3. Report "sent" only after the input box clears (WhatsApp accepted the
 *     tap). Anything else is reported as a failure with a reason.
 *
 * The service is scoped to WhatsApp packages in its XML config, acts only
 * while a job is active, and never reads or stores chat content.
 */
class AutoSendAccessibilityService : AccessibilityService() {

    private data class Job(
        val text: String,
        val pkg: String,
        val startedAt: Long,
        val callback: (Map<String, Any?>) -> Unit,
        var clickedAt: Long = 0L,
    )

    companion object {
        @Volatile
        var instance: AutoSendAccessibilityService? = null
            private set

        private const val OPEN_TIMEOUT_MS = 25_000L
        private const val CONFIRM_TIMEOUT_MS = 5_000L
        private const val POLL_MS = 400L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var job: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private val poll = object : Runnable {
        override fun run() {
            val j = job ?: return
            val now = SystemClock.elapsedRealtime()
            if (j.clickedAt == 0L && now - j.startedAt > OPEN_TIMEOUT_MS) {
                finish("failed", "WhatsApp did not show the chat in time (is the number on WhatsApp?)")
                return
            }
            if (j.clickedAt != 0L && now - j.clickedAt > CONFIRM_TIMEOUT_MS) {
                finish("unconfirmed", "Send was tapped but WhatsApp did not confirm; check the chat")
                return
            }
            step()
            if (job != null) handler.postDelayed(this, POLL_MS)
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        finish("failed", "Auto-send service stopped")
        instance = null
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (job != null) step()
    }

    /** Entry point from the plugin. Always invokes [callback] exactly once. */
    fun send(phoneDigits: String, text: String, pkg: String, callback: (Map<String, Any?>) -> Unit) {
        handler.post {
            if (job != null) {
                callback(result("busy", "Another WhatsApp message is being sent"))
                return@post
            }
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isInteractive) {
                // Turn the screen on so WhatsApp can render. This cannot bypass
                // a PIN/pattern/fingerprint lock, by design.
                @Suppress("DEPRECATION")
                wakeLock = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                    "autometa:wa-send"
                ).apply { acquire(OPEN_TIMEOUT_MS + CONFIRM_TIMEOUT_MS) }
            }
            handler.postDelayed({ begin(phoneDigits, text, pkg, callback) }, if (wakeLock != null) 900L else 0L)
        }
    }

    private fun begin(phoneDigits: String, text: String, pkg: String, callback: (Map<String, Any?>) -> Unit) {
        val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (km.isKeyguardLocked) {
            releaseWake()
            callback(result("locked", "Phone is locked. Auto-send needs the phone unlocked or no screen lock"))
            return
        }
        job = Job(text, pkg, SystemClock.elapsedRealtime(), callback)
        try {
            val uri = Uri.parse("https://api.whatsapp.com/send?phone=$phoneDigits&text=${Uri.encode(text)}")
            startActivity(
                Intent(Intent.ACTION_VIEW, uri)
                    .setPackage(pkg)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            )
        } catch (e: Exception) {
            finish("failed", "Could not open WhatsApp: ${e.message}")
            return
        }
        handler.postDelayed(poll, POLL_MS)
    }

    private fun step() {
        val j = job ?: return
        val root = rootInActiveWindow ?: return
        if (root.packageName?.toString() != j.pkg) return

        val entry = findById(root, "${j.pkg}:id/entry")
        if (j.clickedAt == 0L) {
            val typed = entry?.text?.toString() ?: return
            if (!sameText(typed, j.text)) return // not our message (yet); never send anything else
            val send = findById(root, "${j.pkg}:id/send") ?: findByDescription(root, "Send") ?: return
            if (clickable(send)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) {
                j.clickedAt = SystemClock.elapsedRealtime()
            }
        } else {
            val remaining = entry?.text?.toString().orEmpty()
            if (remaining.isEmpty() || !sameText(remaining, j.text)) {
                finish("sent", null)
            }
        }
    }

    private fun finish(status: String, reason: String?) {
        val j = job ?: return
        job = null
        handler.removeCallbacks(poll)
        if (status == "sent" || status == "unconfirmed") {
            handler.postDelayed({ performGlobalAction(GLOBAL_ACTION_HOME) }, 600L)
        }
        releaseWake()
        j.callback(result(status, reason))
    }

    private fun releaseWake() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun result(status: String, reason: String?): Map<String, Any?> =
        mapOf("status" to status, "reason" to reason)

    private fun sameText(a: String, b: String): Boolean {
        fun norm(s: String) = s.replace(Regex("\\s+"), " ").trim()
        return norm(a) == norm(b)
    }

    private fun findById(root: AccessibilityNodeInfo, id: String): AccessibilityNodeInfo? =
        root.findAccessibilityNodeInfosByViewId(id)?.firstOrNull { it.isVisibleToUser }

    private fun findByDescription(node: AccessibilityNodeInfo, desc: String): AccessibilityNodeInfo? {
        if (node.contentDescription?.toString().equals(desc, ignoreCase = true) && node.isVisibleToUser) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            findByDescription(child, desc)?.let { return it }
        }
        return null
    }

    private fun clickable(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var n: AccessibilityNodeInfo? = node
        while (n != null && !n.isClickable) n = n.parent
        return n
    }
}
