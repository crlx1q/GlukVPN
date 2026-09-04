package tech.gluk.glukvpn

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Replaces the MainActivity that `flutter create` generates.
 *
 * The only thing added on top of the stock activity is [TunnelBridge]: the
 * channel pair that lets Dart draw the ongoing "GlukVPN is connected"
 * notification and lets the Disconnect button in the notification shade reach
 * the running app.
 *
 * CI copies every file from android_overrides/kotlin/ into the generated
 * android/app/src/main/kotlin/<org>/<app>/ folder, so this file replaces the
 * scaffold's own MainActivity.kt.
 */
class MainActivity : FlutterActivity() {
    private var bridge: TunnelBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = TunnelBridge(this).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The engine is going away. The broadcast receiver has to stop
        // believing there is a Dart isolate to hand the request to, otherwise a
        // shade tap would be answered by a channel nobody is listening on.
        bridge?.detach()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
