package com.brianellissound.songitude.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media.session.MediaButtonReceiver
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import com.brianellissound.songitude.MainActivity
import com.brianellissound.songitude.R
import com.brianellissound.songitude.SongitudeApp

/**
 * Keeps the walk rendering while the phone is locked and in a pocket.
 *
 * This is the biggest structural difference from iOS. There, an audio session plus the "audio"
 * background mode is enough and nothing is shown to the user. Android requires a foreground service
 * with a visible, persistent notification, and — since Android 14 — the service must declare both
 * why it is running: mediaPlayback and location. The notification doubles as the lock-screen
 * transport, standing in for MPNowPlayingInfoCenter.
 */
class PlaybackService : Service() {

    private lateinit var session: MediaSessionCompat

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val engine = (application as SongitudeApp).engine
        session = MediaSessionCompat(this, "Songitude").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { engine.handleRemoteTransport(true) }
                override fun onPause() { engine.handleRemoteTransport(false) }
                override fun onStop() { engine.handleRemoteTransport(false) }
                override fun onSkipToNext() { engine.skip(com.brianellissound.songitude.audio.RenderEngine.SKIP_INTERVAL_SECONDS) }
                override fun onSkipToPrevious() { engine.skip(-com.brianellissound.songitude.audio.RenderEngine.SKIP_INTERVAL_SECONDS) }
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as SongitudeApp
        when (intent?.action) {
            ACTION_TOGGLE -> app.engine.handleRemoteTransport(null)
            ACTION_STOP -> {
                app.engine.handleRemoteTransport(false)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        val title = app.engine.let { "Songitude" }
        val running = app.engine.isRunning.value
        val notification = buildNotification(running)

        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
        } else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)

        // Keep the transport state honest so the lock screen shows the right control.
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(
                    if (running) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                    1f,
                )
                .build()
        )
        return START_STICKY
    }

    private fun buildNotification(running: Boolean): android.app.Notification {
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val toggle = PendingIntent.getService(
            this, 1,
            Intent(this, PlaybackService::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 2,
            Intent(this, PlaybackService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle("Songitude")
            .setContentText(if (running) "Listening to where you are" else "Paused")
            .setContentIntent(open)
            .setOngoing(running)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .addAction(
                if (running) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                if (running) "Pause" else "Play",
                toggle,
            )
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stop)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(session.sessionToken)
                    .setShowActionsInCompactView(0)
            )
            .build()
    }

    override fun onDestroy() {
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "songitude.playback"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_TOGGLE = "com.brianellissound.songitude.TOGGLE"
        const val ACTION_STOP = "com.brianellissound.songitude.STOP"

        fun createChannel(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Playback",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shows while a soundwalk is playing"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }

        fun start(context: Context) {
            val i = Intent(context, PlaybackService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i)
            else context.startService(i)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
