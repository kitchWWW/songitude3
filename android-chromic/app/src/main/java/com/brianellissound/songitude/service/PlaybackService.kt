package com.brianellissound.songitude.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.media.session.MediaButtonReceiver
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import com.brianellissound.songitude.MainActivity
import com.brianellissound.songitude.R
import com.brianellissound.songitude.ui.Brand
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

    /** Non-null while the "open the app to resume" message is speaking; see [refuseBackgroundResume]. */
    private var notice: MediaPlayer? = null

    /** Already foreground: a refresh only redraws. Re-promoting with the location type from the
     *  background is exactly what Android can refuse, and that must not read as a refused resume. */
    private var inForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val engine = (application as SongitudeApp).engine
        session = MediaSessionCompat(this, Brand.NAME).apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() { engine.handleRemoteTransport(true) }
                override fun onPause() { engine.handleRemoteTransport(false) }
                override fun onStop() { engine.handleRemoteTransport(false) }
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
                (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(NOTIFICATION_ID)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        val title = app.engine.let { Brand.NAME }
        val running = app.engine.isRunning.value
        // What the listener hears, which is what the transport shows. Still foreground while
        // interrupted, so the walk can come back in place.
        val sounding = running && !app.engine.isInterrupted.value
        val notification = buildNotification(sounding)

        if (running && inForeground) {
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        } else if (running) {
            val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            } else 0
            try {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types)
                inForeground = true
            } catch (e: SecurityException) {
                refuseBackgroundResume()
                return START_STICKY
            }
        } else if (notice != null) {
            // The walk was just paused by refuseBackgroundResume. Stay foreground until the message
            // finishes, or Android may cut it off mid-sentence.
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        } else {
            // Paused: stop being a foreground service — nothing is playing and nothing needs the
            // process kept alive — but leave the notification standing, detached, so the transport
            // is still there to resume from.
            //
            // Tearing it down instead was a real difference from iOS: pausing from the lock screen
            // removed the only control that could start the walk again, so a pause was effectively
            // a stop. iOS keeps its Now Playing entry with a rate of 0 for the same reason.
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
            inForeground = false
            (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .notify(NOTIFICATION_ID, notification)
        }

        // Keep the transport state honest so the lock screen shows the right control.
        session.setPlaybackState(
            PlaybackStateCompat.Builder()
                // Play, pause and stop only. A soundwalk is not a seekable medium and has no next
                // track; iOS disables exactly these commands, and offering them here would put
                // controls on the lock screen that the walk cannot honour.
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or PlaybackStateCompat.ACTION_STOP
                )
                .setState(
                    if (sounding) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED,
                    PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                    1f,
                )
                .build()
        )
        return START_STICKY
    }

    /**
     * Play was pressed from somewhere Android doesn't count as the user being in the app — a
     * headset or Bluetooth button after a pause — so it refused a location foreground service.
     *
     * We only hold while-in-use location (background location got 1.0.1 rejected on Play). Resuming
     * anyway would play a walk that can no longer hear where the listener is, so instead the walk
     * stays paused and a spoken message asks them to open the app. Interacting with the
     * notification is exempt and never lands here. iOS has no equivalent: "Always" is granted there.
     */
    private fun refuseBackgroundResume() {
        (application as SongitudeApp).engine.handleRemoteTransport(false)
        // startForegroundService was already called, so the service must go foreground or Android
        // kills the app. Media playback alone needs no location grant.
        val types = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(false), types)
        if (notice != null) return

        val afd = resources.openRawResourceFd(R.raw.resume_needs_app)
        notice = MediaPlayer().apply {
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
            afd.close()
            setOnCompletionListener { finishNotice() }
            setOnErrorListener { _, _, _ -> finishNotice(); true }
            prepare()
            start()
        }
    }

    /** The message is over: back to the paused state, notification left standing to resume from. */
    private fun finishNotice() {
        notice?.release()
        notice = null
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        inForeground = false
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, buildNotification(false))
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
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(Brand.NAME)
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

    /**
     * The app was swiped out of Recents. On iOS a force-quit tears the audio session down and the
     * walk stops; swiping away is the same gesture, so it should mean the same thing rather than
     * leaving a walk playing behind a notification nobody asked for.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        (application as SongitudeApp).engine.handleRemoteTransport(false)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        notice?.release()
        notice = null
        session.isActive = false
        session.release()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "songitude.playback"
        private const val NOTIFICATION_ID = 1001
        const val ACTION_TOGGLE = "com.brianellissound.songitude.TOGGLE"
        const val ACTION_STOP = "com.brianellissound.songitude.STOP"
        const val ACTION_REFRESH = "com.brianellissound.songitude.REFRESH"

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

        /** Playback paused. The service is told, rather than killed, so its notification survives
         *  as something to resume from. */
        fun pause(context: Context) {
            val i = Intent(context, PlaybackService::class.java).setAction(ACTION_REFRESH)
            runCatching { context.startService(i) }
        }

        /** Redraw the notification after an interruption begins or ends; changes nothing else. */
        fun refresh(context: Context) {
            val i = Intent(context, PlaybackService::class.java).setAction(ACTION_REFRESH)
            runCatching { context.startService(i) }
        }

        /** The walk is done with entirely. */
        fun stop(context: Context) {
            context.stopService(Intent(context, PlaybackService::class.java))
        }
    }
}
