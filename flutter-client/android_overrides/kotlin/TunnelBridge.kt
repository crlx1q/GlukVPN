package tech.gluk.glukvpn

import android.app.Activity
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Dart <-> platform bridge for the tunnel notification.
 *
 * Two directions:
 *
 *  * **Dart -> platform** (MethodChannel `tech.gluk.glukvpn/tunnel`):
 *    `show` / `hide` draw and remove the ongoing notification, and
 *    `consumeStopRequest` reads back a Disconnect that was pressed while no
 *    isolate was listening.
 *  * **platform -> Dart** (EventChannel `tech.gluk.glukvpn/tunnel_events`):
 *    one event, [EVENT_DISCONNECT], sent when the shade button is pressed and
 *    the app is still running.
 *
 * The stop request is *always* written to SharedPreferences first, before any
 * attempt to reach Dart. That record is what makes the state survive a killed
 * process: the app can never come back showing "Connected" over a tunnel the
 * user has already stopped from the shade.
 */
class TunnelBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        methods = MethodChannel(messenger, METHOD_CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(messenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
        live = this
    }

    fun detach() {
        if (live === this) live = null
        sink = null
        methods?.setMethodCallHandler(null)
        methods = null
        events?.setStreamHandler(null)
        events = null
    }

    // ---- MethodChannel -----------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "show" -> {
                val title = call.argument<String>("title").orEmpty()
                val body = call.argument<String>("body").orEmpty()
                val action = call.argument<String>("actionLabel").orEmpty()
                val stopping = call.argument<String>("stoppingLabel").orEmpty()
                val channelName = call.argument<String>("channelName").orEmpty()
                if (title.isEmpty() || action.isEmpty()) {
                    result.error(
                        "bad_arguments",
                        "title and actionLabel are required",
                        null,
                    )
                    return
                }
                // The receiver runs without Dart, so the copy it needs while
                // tearing the tunnel down is stored here in the interface
                // language rather than hard-coded in Kotlin.
                prefs(activity).edit()
                    .putString(KEY_STOPPING_TITLE, stopping)
                    .putString(KEY_CHANNEL_NAME, channelName)
                    .apply()
                ensureNotificationPermission()
                TunnelNotificationService.show(
                    context = activity,
                    title = title,
                    body = body,
                    actionLabel = action,
                    channelName = channelName,
                )
                result.success(null)
            }

            "hide" -> {
                TunnelNotificationService.hide(activity)
                result.success(null)
            }

            "consumeStopRequest" -> {
                val store = prefs(activity)
                val requested = store.getBoolean(KEY_STOP_REQUESTED, false)
                if (requested) store.edit().remove(KEY_STOP_REQUESTED).apply()
                result.success(requested)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Android 13+ hides notifications from apps that were never granted
     * POST_NOTIFICATIONS - including the one carrying the Disconnect button.
     * Asked for at connect time, which is the only moment it makes sense.
     */
    private fun ensureNotificationPermission() {
        if (Build.VERSION.SDK_INT < 33) return
        val granted = activity.checkSelfPermission(POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        if (granted) return
        try {
            activity.requestPermissions(
                arrayOf(POST_NOTIFICATIONS),
                PERMISSION_REQUEST,
            )
        } catch (error: Exception) {
            Log.w(TAG, "could not ask for the notification permission: $error")
        }
    }

    // ---- EventChannel ------------------------------------------------------

    override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    companion object {
        private const val TAG = "GlukTunnelBridge"

        const val METHOD_CHANNEL = "tech.gluk.glukvpn/tunnel"
        const val EVENT_CHANNEL = "tech.gluk.glukvpn/tunnel_events"
        const val EVENT_DISCONNECT = "disconnect_requested"

        /**
         * Written as a literal so the file still compiles against an SDK older
         * than 33; it is only ever used behind a Build.VERSION check.
         */
        private const val POST_NOTIFICATIONS =
            "android.permission.POST_NOTIFICATIONS"
        private const val PERMISSION_REQUEST = 8321

        private const val PREFS = "glukvpn_tunnel"
        private const val KEY_STOP_REQUESTED = "stop_requested"
        const val KEY_STOPPING_TITLE = "stopping_title"
        const val KEY_CHANNEL_NAME = "channel_name"

        private val main = Handler(Looper.getMainLooper())

        /** The bridge of the engine that is currently alive, if any. */
        private var live: TunnelBridge? = null

        fun prefs(context: Context): SharedPreferences =
            context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

        /** Records a Disconnect the app has not served yet. */
        fun rememberStopRequest(context: Context) {
            prefs(context).edit().putBoolean(KEY_STOP_REQUESTED, true).apply()
        }

        /**
         * Hands the request to a running Dart isolate.
         *
         * Returns false when there is none - the activity may have been
         * destroyed while a foreground service kept the process warm - and the
         * caller then falls back to waking the app up.
         */
        fun dispatchDisconnect(): Boolean {
            val target = live?.sink ?: return false
            main.post {
                try {
                    target.success(EVENT_DISCONNECT)
                } catch (error: Exception) {
                    Log.w(TAG, "could not deliver the shade request: $error")
                }
            }
            return true
        }
    }
}
