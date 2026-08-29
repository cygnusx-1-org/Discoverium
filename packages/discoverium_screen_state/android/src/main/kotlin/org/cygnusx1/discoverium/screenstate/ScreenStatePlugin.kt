package org.cygnusx1.discoverium.screenstate

import android.app.KeyguardManager
import android.content.Context
import android.os.PowerManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reports whether the device is locked, so background updates can be held back
 * until the phone is idle (replacing a running app kills it).
 *
 * This is a plugin rather than a channel on MainActivity because the update
 * installs happen in the WorkManager background isolate, which has its own
 * FlutterEngine and no activity: only registered plugins are reachable there.
 *
 * Nothing here needs a permission.
 */
class ScreenStatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private companion object {
        const val CHANNEL = "org.cygnusx1.discoverium/screen_state"
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler(this@ScreenStatePlugin)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("NO_CONTEXT", "Plugin is not attached to an engine", null)
            return
        }
        when (call.method) {
            "isLocked" -> result.success(isLocked(ctx))
            else -> result.notImplemented()
        }
    }

    /**
     * Whether the user is shut out of the device: the keyguard is showing, or
     * the screen is off.
     *
     * The screen-off case matters on its own because a device with no lock
     * method configured never reports a locked keyguard, and a dark screen is
     * just as good a sign that nobody is looking at the app about to be
     * replaced.
     */
    private fun isLocked(ctx: Context): Boolean {
        val keyguard = ctx.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (keyguard?.isKeyguardLocked == true) return true
        val power = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager
        return power?.isInteractive == false
    }
}
