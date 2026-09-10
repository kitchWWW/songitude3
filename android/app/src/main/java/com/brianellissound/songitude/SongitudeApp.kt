package com.brianellissound.songitude

import android.app.Application
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.location.SongitudeLocationManager
import com.brianellissound.songitude.service.PlaybackService

/**
 * The engine and the location manager are owned by the Application, not the Activity.
 *
 * On iOS the app object keeps rendering in the background because the audio session and the
 * "audio" background mode hold the process. Android needs the same lifetime for a different
 * reason: a foreground service keeps the process alive, and it has to talk to the *same* engine
 * the UI is driving. Tying either to the Activity would silence the walk on a rotation.
 */
class SongitudeApp : Application() {

    val engine: RenderEngine by lazy { RenderEngine(this) }
    val location: SongitudeLocationManager by lazy { SongitudeLocationManager(this) }

    override fun onCreate() {
        super.onCreate()
        PlaybackService.createChannel(this)
        // Playback starting or stopping is what starts and stops the foreground service, wherever
        // the transport was driven from — the button, the notification, or a headphone unplug.
        engine.onRunningChanged = { running ->
            if (running) PlaybackService.start(this) else PlaybackService.stop(this)
        }
    }
}
