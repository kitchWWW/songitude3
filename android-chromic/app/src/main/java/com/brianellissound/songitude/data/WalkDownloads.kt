package com.brianellissound.songitude.data

import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.SoundMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Every walk download in flight, one per walk id, owned by the Application.
 *
 * The walk's page starts a download the moment it opens ([prefetch]) so the audio is mostly or
 * entirely on disk by the time Start is pressed; Start then [claim]s that same download rather than
 * beginning a second one from zero. Both ends can be in different Activities — Android may destroy
 * the one that started it while the listener reads the page with the screen off — so neither the
 * download nor this table can live in a ViewModel: `viewModelScope` would cancel it, and a new
 * AppState would not know it existed. Main thread only.
 */
class WalkDownloads(private val downloader: WalkDownloader) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val inFlight = HashMap<String, Download>()

    /** One walk's download. Observers read [progress] and [map]; [await] returns its outcome. */
    class Download internal constructor(val walk: RemoteWalk) {
        internal val progressFlow = MutableStateFlow(0.0)
        internal val mapFlow = MutableStateFlow<SoundMap?>(null)
        internal val result = CompletableDeferred<Result<Experience>>()
        internal lateinit var job: Job
        internal var cancelled = false

        /** 0–1, by bytes where the manifest gives a size. */
        val progress: StateFlow<Double> = progressFlow.asStateFlow()
        /** Non-null once map.json has landed, long before the audio. */
        val map: StateFlow<SoundMap?> = mapFlow.asStateFlow()
        /** Start has joined it. Until then it is speculative, and may be superseded. */
        var claimed = false
            internal set

        suspend fun await(): Result<Experience> = result.await()
    }

    /** Walk ids with a download still running (cancelled ones included until they wind down). */
    fun ids(): Set<String> = inFlight.keys.toSet()

    /**
     * Start downloading [walk] because its page is open. The caller has already ruled out a walk
     * that is loaded or cached at the published revision.
     *
     * Backing out of the page does not cancel it: the rest of a half-downloaded walk is usually a
     * few more seconds, and finishing means the next visit opens instantly. Files are written to a
     * `.part` and moved into place, and `.complete` is written last, so an interrupted download is
     * only ever resumed, never trusted. What *does* stop it is opening a different walk's page:
     * browsing through a few pages costs one download, not one per page. A claimed download is
     * never superseded.
     */
    fun prefetch(walk: RemoteWalk): Download {
        inFlight.values.filter { !it.claimed && it.walk.id != walk.id }.forEach { stop(it) }
        return ensure(walk)
    }

    /** The download for [walk], joined if it is already running, and marked as the listener's. */
    fun claim(walk: RemoteWalk): Download = ensure(walk).also { it.claimed = true }

    /** Stop the download for [id], for a walk whose files are about to be deleted. */
    fun cancel(id: String) { inFlight[id]?.let { stop(it) } }

    fun cancelAll() { inFlight.values.toList().forEach { stop(it) } }

    private fun stop(d: Download) {
        d.cancelled = true
        d.job.cancel()
    }

    private fun ensure(walk: RemoteWalk): Download {
        val existing = inFlight[walk.id]
        if (existing != null && !existing.cancelled) return existing
        // A cancelled one for the same walk may still be closing its last `.part`; let it finish
        // cleaning up before this one writes the same names.
        val prior = existing?.job
        val d = Download(walk)
        inFlight[walk.id] = d
        d.job = scope.launch {
            try {
                prior?.join()
                val r = downloader.download(
                    walk,
                    mapReady = { d.mapFlow.value = it },
                    progress = { d.progressFlow.value = it },
                )
                d.result.complete(r)
            } finally {
                // Reached on cancellation too, so an observer never waits forever.
                d.result.complete(Result.failure(CancellationException("download cancelled")))
                if (inFlight[walk.id] === d) inFlight.remove(walk.id)
            }
        }
        return d
    }
}
