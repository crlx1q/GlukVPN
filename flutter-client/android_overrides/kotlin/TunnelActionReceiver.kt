package tech.gluk.glukvpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * The Disconnect button in the notification shade.
 *
 * The order below is the whole design, and every step matters:
 *
 *  1. **Record it.** Before anything that can fail, the request is written to
 *     SharedPreferences. If the process dies in the next millisecond, the app
 *     consumes that record on its next start and tears the tunnel down there,
 *     so the screen can never come back saying "Connected" over a tunnel the
 *     user has already killed from the shade.
 *  2. **Answer in the shade.** The teardown takes a moment; a button that does
 *     nothing visible reads as a broken app, so the notification switches to
 *     "Disconnecting" immediately.
 *  3. **Let the app do the work.** Dart owns the tunnel handle and the session
 *     id, so it is the only side that can both stop wireguard-go and close the
 *     session with POST /api/vpn/disconnect. This is the normal path: the app
 *     is in the background but alive.
 *  4. **Wake the app if the isolate is gone.** A notification action is one of
 *     the cases where Android still allows an app to start an activity from
 *     the background, so the app comes up, consumes the record from step 1 and
 *     finishes the teardown.
 */
class TunnelActionReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DISCONNECT) return

        TunnelBridge.rememberStopRequest(context)
        TunnelNotificationService.markStopping(context)

        if (TunnelBridge.dispatchDisconnect()) return

        Log.i(TAG, "no live isolate for the shade request, waking the app up")
        try {
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (error: Exception) {
            // Nothing else can be done from here, and the record from step 1
            // still guarantees the state is correct the next time the app runs.
            Log.w(TAG, "could not wake the app up: $error")
        }
    }

    companion object {
        private const val TAG = "GlukTunnelAction"

        const val ACTION_DISCONNECT = "tech.gluk.glukvpn.action.DISCONNECT"
    }
}
