package app.taxicount.taxicount

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Notificaciones con sonido propio (claxon doble, res/raw/claxon.wav).
 *
 * - Canal "taxicount_claxon" (importancia ALTA -> aviso flotante) con el claxon.
 *   Las push de FCM lo usan: el backend lo pide en el mensaje y el manifiesto lo
 *   fija como canal por defecto. OJO: Android congela el sonido de un canal al
 *   crearlo; para cambiar de sonido hay que crear un canal con OTRO id.
 * - Con la app ABIERTA, Android no muestra la push de FCM: Dart llama a
 *   `taxicount/notify` -> show para mostrarla igualmente (con su claxon).
 */
class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL_ID = "taxicount_claxon"

        fun soundUri(ctx: Context): Uri =
            Uri.parse("android.resource://${ctx.packageName}/raw/claxon")

        fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(CHANNEL_ID, "Avisos de TaxiCount", NotificationManager.IMPORTANCE_HIGH)
            ch.description = "Agenda, mantenimiento, mensajes y avisos de TaxiCount"
            ch.setSound(
                soundUri(ctx),
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            ch.enableVibration(true)
            nm.createNotificationChannel(ch)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureChannel(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taxicount/notify")
            .setMethodCallHandler { call, result ->
                if (call.method == "show") {
                    try {
                        showNow(
                            call.argument<String>("title") ?: "TaxiCount",
                            call.argument<String>("body") ?: ""
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false) // sin permiso u otro fallo: nunca rompe la app
                    }
                } else if (call.method == "timezone") {
                    // Zona horaria del móvil (IANA): los informes Excel/PDF ponen la
                    // misma hora que enseña la app.
                    result.success(java.util.TimeZone.getDefault().id)
                } else {
                    result.notImplemented()
                }
            }
    }

    @Suppress("DEPRECATION")
    private fun showNow(title: String, body: String) {
        ensureChannel(this)
        val intent = (packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
                .setSound(soundUri(this))
                .setPriority(Notification.PRIORITY_HIGH)
                .setDefaults(Notification.DEFAULT_VIBRATE)
        }
        b.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(pi)
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), b.build())
    }
}
