package tech.gluk.glukvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * The ongoing notification that carries the Disconnect button.
 *
 * Why a service of our own exists at all: the tunnel is raised by
 * `wireguard_flutter`, and the notification its own foreground service posts
 * cannot be customised - the package builds it internally and exposes no way to
 * add an action. So GlukVPN posts its own ongoing notification, and that is the
 * one with the button. It is a foreground service rather than a plain
 * notification so Android 14+ cannot let the user swipe away a control for a
 * tunnel that is still running.
 *
 * The service draws and nothing else. Pressing the button goes to
 * [TunnelActionReceiver], and the actual teardown - stopping wireguard-go and
 * closing the session with POST /api/vpn/disconnect - is done by the Dart
 * controller, which is the only side that owns the tunnel handle and the
 * session id.
 */
class TunnelNotificationService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_HIDE) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE).orEmpty()
        val body = intent?.getStringExtra(EXTRA_BODY).orEmpty()
        val action = intent?.getStringExtra(EXTRA_ACTION).orEmpty()
        val channelName = intent?.getStringExtra(EXTRA_CHANNEL_NAME).orEmpty()

        if (title.isEmpty() || action.isEmpty()) {
            // Nothing sensible to draw. This only happens if Android restarts
            // the service with a null intent, and a notification for a tunnel
            // that may well be gone would be a lie.
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        val notification = build(this, title, body, action, channelName)
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, FGS_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (error: Exception) {
            // Android 12+ refuses a foreground start from the background. The
            // button still has to reach the shade, so fall back to a plain
            // post: the plugin's own service is what keeps the process alive.
            Log.w(TAG, "startForeground refused, posting instead: $error")
            notify(this, notification)
        }

        // Deliberately not sticky: if the process dies the tunnel dies with it,
        // and a notification restored by the system would offer to disconnect
        // something that is already gone.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopForegroundCompat()
        super.onDestroy()
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= 24) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (error: Exception) {
            Log.w(TAG, "stopForeground failed: $error")
        }
        notificationManager(this)?.cancel(NOTIFICATION_ID)
    }

    companion object {
        private const val TAG = "GlukTunnelNotification"

        private const val ACTION_SHOW = "tech.gluk.glukvpn.notification.SHOW"
        private const val ACTION_HIDE = "tech.gluk.glukvpn.notification.HIDE"

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_BODY = "body"
        private const val EXTRA_ACTION = "action"
        private const val EXTRA_CHANNEL_NAME = "channelName"

        private const val CHANNEL_ID = "glukvpn_tunnel"
        private const val NOTIFICATION_ID = 7311

        /**
         * ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE, spelled out so the
         * file compiles against an SDK older than 34. The three-argument
         * startForeground has existed since API 29.
         */
        private const val FGS_TYPE_SPECIAL_USE = 1 shl 30

        /** Draws (or refreshes) the notification for a live tunnel. */
        fun show(
            context: Context,
            title: String,
            body: String,
            actionLabel: String,
            channelName: String,
        ) {
            val intent = Intent(context, TunnelNotificationService::class.java)
                .setAction(ACTION_SHOW)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_BODY, body)
                .putExtra(EXTRA_ACTION, actionLabel)
                .putExtra(EXTRA_CHANNEL_NAME, channelName)
            try {
                if (Build.VERSION.SDK_INT >= 26) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (error: Exception) {
                Log.w(TAG, "service start refused, posting instead: $error")
                notify(context, build(context, title, body, actionLabel, channelName))
            }
        }

        /**
         * Swaps the notification for a "disconnecting" line the moment the
         * button is pressed.
         *
         * Posted straight through the NotificationManager rather than by
         * starting the service again: this runs inside a broadcast receiver,
         * where a foreground-service start is refused on Android 12+, and the
         * id is the one the service already owns, so the update lands in place.
         */
        fun markStopping(context: Context) {
            val store = TunnelBridge.prefs(context)
            val title = store.getString(TunnelBridge.KEY_STOPPING_TITLE, null)
                ?.takeIf { it.isNotEmpty() } ?: "Disconnecting"
            val channelName = store.getString(TunnelBridge.KEY_CHANNEL_NAME, null)
                .orEmpty()
            notify(context, build(context, title, "", null, channelName))
        }

        /**
         * Removes the notification.
         *
         * stopService, not another start: stopping a service is allowed from
         * the background, while starting one is not, and this can be called
         * right after a teardown that began in the shade.
         */
        fun hide(context: Context) {
            try {
                context.stopService(
                    Intent(context, TunnelNotificationService::class.java),
                )
            } catch (error: Exception) {
                Log.w(TAG, "stopService failed: $error")
            }
            notificationManager(context)?.cancel(NOTIFICATION_ID)
        }

        private fun notificationManager(context: Context): NotificationManager? =
            context.getSystemService(Context.NOTIFICATION_SERVICE)
                as? NotificationManager

        private fun notify(context: Context, notification: Notification) {
            try {
                notificationManager(context)?.notify(NOTIFICATION_ID, notification)
            } catch (error: Exception) {
                Log.w(TAG, "notify failed: $error")
            }
        }

        private fun build(
            context: Context,
            title: String,
            body: String,
            actionLabel: String?,
            channelName: String,
        ): Notification {
            ensureChannel(context, channelName)

            val open = PendingIntent.getActivity(
                context,
                1,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP),
                pendingFlags(),
            )

            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context).setPriority(Notification.PRIORITY_LOW)
            }

            builder
                .setContentTitle(title)
                .setSmallIcon(smallIcon(context))
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
            if (body.isNotEmpty()) builder.setContentText(body)
            if (Build.VERSION.SDK_INT >= 21) {
                builder.setVisibility(Notification.VISIBILITY_PUBLIC)
                builder.setCategory(Notification.CATEGORY_SERVICE)
            }

            if (!actionLabel.isNullOrEmpty()) {
                val stop = PendingIntent.getBroadcast(
                    context,
                    2,
                    Intent(context, TunnelActionReceiver::class.java)
                        .setAction(TunnelActionReceiver.ACTION_DISCONNECT),
                    pendingFlags(),
                )
                // The int-icon overload is deprecated but works on every API
                // level, and notification action icons have not been drawn
                // since Android 7 anyway.
                @Suppress("DEPRECATION")
                builder.addAction(0, actionLabel, stop)
            }

            return builder.build()
        }

        private fun ensureChannel(context: Context, channelName: String) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = notificationManager(context) ?: return
            val name = channelName.takeIf { it.isNotEmpty() } ?: "VPN status"
            val channel = NotificationChannel(
                CHANNEL_ID,
                name,
                NotificationManager.IMPORTANCE_LOW,
            )
            channel.setShowBadge(false)
            channel.enableVibration(false)
            channel.setSound(null, null)
            // Same id on every call, so this also renames the channel after the
            // user switches the interface language.
            manager.createNotificationChannel(channel)
        }

        /**
         * The app's monochrome launcher layer, which is exactly what a status
         * icon needs. Falls back to the launcher icon if the artwork is ever
         * renamed.
         */
        private fun smallIcon(context: Context): Int {
            val monochrome = context.resources.getIdentifier(
                "ic_launcher_monochrome",
                "mipmap",
                context.packageName,
            )
            return if (monochrome != 0) monochrome else context.applicationInfo.icon
        }

        private fun pendingFlags(): Int {
            var flags = PendingIntent.FLAG_UPDATE_CURRENT
            if (Build.VERSION.SDK_INT >= 23) {
                flags = flags or PendingIntent.FLAG_IMMUTABLE
            }
            return flags
        }
    }
}
