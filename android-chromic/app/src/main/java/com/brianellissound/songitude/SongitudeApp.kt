package com.brianellissound.songitude

import android.app.Application
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.location.SongitudeLocationManager
import com.brianellissound.songitude.model.Experience
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

    /**
     * The walk currently loaded, as placed — held here rather than in the AppState ViewModel.
     *
     * Android will tear the Activity down while a walk plays with the screen off, and a ViewModel
     * goes with it. Keeping the loaded walk only there meant coming back to a running foreground
     * service, audio still playing, and a UI that believed nothing was loaded — so it opened the
     * walks list instead of the map with its pause button. iOS never has this problem because its
     * AppState lives as long as the app does.
     *
     * Cleared when the process dies, which is the right behaviour: a full quit should open on the
     * selector, exactly as iOS does.
     */
    @Volatile
    var loadedExperience: Experience? = null

    override fun onCreate() {
        super.onCreate()
        PlaybackService.createChannel(this)
        // Playback starting or stopping is what starts and stops the foreground service, wherever
        // the transport was driven from — the button, the notification, or a headphone unplug.
        engine.onRunningChanged = { running ->
            // Pausing tells the service rather than killing it, so its transport stays on the lock
            // screen to resume from — the way iOS keeps its Now Playing entry at a rate of 0.
            if (running) PlaybackService.start(this) else PlaybackService.pause(this)
        }
    }
}
