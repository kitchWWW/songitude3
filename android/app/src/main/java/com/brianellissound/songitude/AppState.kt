package com.brianellissound.songitude

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.data.ArtistProfile
import com.brianellissound.songitude.data.CatalogService
import com.brianellissound.songitude.data.ExperienceLibrary
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.data.WalkDownloader
import com.brianellissound.songitude.location.SongitudeLocationManager
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.GeoUtils
import com.brianellissound.songitude.model.LatLngD
import com.brianellissound.songitude.model.WalkTransposition
import com.brianellissound.songitude.model.transposed
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/** How the app renders light/dark. Defaults to following the phone. */
enum class AppAppearance(val key: String, val label: String) {
    SYSTEM("system", "System"), LIGHT("light", "Light"), DARK("dark", "Dark");

    companion object {
        fun from(key: String?) = entries.firstOrNull { it.key == key } ?: SYSTEM
    }
}

/**
 * App-wide coordinator: owns the bundled library, the remote catalog, the location manager and the
 * render engine, and wires location fixes into playback.
 *
 * Ported from ios/.../AppState.swift. The GPS slewing, the intro/far-away card gating, the
 * transportable-walk placement and the download supersede rules are all carried over intact,
 * because each of them exists to fix a bug the iOS app already hit.
 */
class AppState(app: Application) : AndroidViewModel(app) {

    private val ctx: Context get() = getApplication()
    private val prefs = ctx.getSharedPreferences("songitude", Context.MODE_PRIVATE)

    // Engine and location live on the Application so a rotation, or the Activity going away while
    // the phone is pocketed, never silences a walk in progress.
    val location: SongitudeLocationManager = (app as SongitudeApp).location
    val engine: RenderEngine = (app as SongitudeApp).engine
    val downloader = WalkDownloader(ctx)

    // MARK: - Published state

    private val _experiences = MutableStateFlow<List<Experience>>(emptyList())
    val experiences: StateFlow<List<Experience>> = _experiences.asStateFlow()

    private val _current = MutableStateFlow<Experience?>(null)
    val current: StateFlow<Experience?> = _current.asStateFlow()

    private val _offset = MutableStateFlow(CoordinateOffset.NONE)
    val offset: StateFlow<CoordinateOffset> = _offset.asStateFlow()

    private val _hasOnboarded = MutableStateFlow(prefs.getBoolean(ONBOARD_KEY, false))
    val hasOnboarded: StateFlow<Boolean> = _hasOnboarded.asStateFlow()

    private val _appearance = MutableStateFlow(AppAppearance.from(prefs.getString(APPEARANCE_KEY, null)))
    val appearance: StateFlow<AppAppearance> = _appearance.asStateFlow()

    private val _showPermissionDeniedAlert = MutableStateFlow(false)
    val showPermissionDeniedAlert: StateFlow<Boolean> = _showPermissionDeniedAlert.asStateFlow()

    private val _showIntroCard = MutableStateFlow(false)
    val showIntroCard: StateFlow<Boolean> = _showIntroCard.asStateFlow()

    /** Follows the intro card when the listener is nowhere near a geo-locked walk. Advisory only. */
    private val _showFarAwayCard = MutableStateFlow(false)
    val showFarAwayCard: StateFlow<Boolean> = _showFarAwayCard.asStateFlow()

    /** How many times the card has been opened for the loaded walk. The recenter control only
     *  appears from the second viewing, so a first read is just the walk's own words. */
    private val _introShowings = MutableStateFlow(0)
    val introShowings: StateFlow<Int> = _introShowings.asStateFlow()

    /** Bumped every time a transportable walk is placed, so the map redraws its overlays even
     *  though the walk's id hasn't changed. */
    private val _placementVersion = MutableStateFlow(0)
    val placementVersion: StateFlow<Int> = _placementVersion.asStateFlow()

    private val _downloadedIds = MutableStateFlow<Set<String>>(emptySet())
    val downloadedIds: StateFlow<Set<String>> = _downloadedIds.asStateFlow()

    private val _resetToken = MutableStateFlow(0)
    val resetToken: StateFlow<Int> = _resetToken.asStateFlow()

    private val _downloadingWalkId = MutableStateFlow<String?>(null)
    val downloadingWalkId: StateFlow<String?> = _downloadingWalkId.asStateFlow()

    private val _downloadProgress = MutableStateFlow(0.0)
    val downloadProgress: StateFlow<Double> = _downloadProgress.asStateFlow()

    private val _catalogError = MutableStateFlow<String?>(null)
    val catalogError: StateFlow<String?> = _catalogError.asStateFlow()

    // Catalog
    private val _walks = MutableStateFlow<List<RemoteWalk>>(emptyList())
    val walks: StateFlow<List<RemoteWalk>> = _walks.asStateFlow()

    private val _catalogLoading = MutableStateFlow(false)
    val catalogLoading: StateFlow<Boolean> = _catalogLoading.asStateFlow()

    private val _artists = MutableStateFlow<Map<String, ArtistProfile>>(emptyMap())
    val artists: StateFlow<Map<String, ArtistProfile>> = _artists.asStateFlow()
    private val artistsInFlight = HashSet<String>()

    // MARK: - Internal

    /** Deep link to open once onboarding/catalog allows. */
    private var pendingWalkId: String? = null
    /** The walk the listener most recently asked for. A download finishing after they have moved on
     *  must not steer the UI — its files just land in the cache for next time. */
    private var activeWalkRequest: String? = null
    /** The walk exactly as authored, before any transposition. Re-anchoring starts from this, or
     *  each recenter would compound on the last one's transform. */
    private var authoredCurrent: Experience? = null
    private var pendingRecenter = false
    /** A portable walk placed before the compass reported gets one free re-place when it does. */
    private var pendingHeadingPlacement = false
    private var pendingFarAwayCheck = false
    private var downloadJob: Job? = null

    // GPS slewing: feed the engine a virtual position that eases toward each new fix in small steps,
    // so a jumpy GPS reading can't teleport across (and skip) a zone.
    private var virtualCoord: LatLngD? = null
    private var slewJob: Job? = null

    val selectedExperience: Experience? get() = _current.value

    /** True while a specific walk is already on its way in — a deep link waiting on the catalog, or
     *  one being opened right now. The map shouldn't pop the walks list over the top of it. */
    val isOpeningWalk: Boolean get() = pendingWalkId != null || activeWalkRequest != null

    companion object {
        private const val ONBOARD_KEY = "hasOnboarded.v1"
        private const val SPLASH_KEY = "splash.seen.v1"
        private const val APPEARANCE_KEY = "appearance.v1"
        /** How long an intro card stays "already seen" for a walk. Deliberately loose: moving around
         *  the app shouldn't re-show it, but coming back later should. */
        private const val INTRO_WINDOW_SECONDS = 600.0
        /** Far enough that none of a fixed walk can be reached on foot — 50 miles. */
        private const val FAR_AWAY_DISTANCE_M = 80_467.0
    }

    init {
        _experiences.value = ExperienceLibrary.loadAll(ctx)
        // A walk still loaded from earlier in this process — the Activity was recreated while it
        // played, most likely with the phone pocketed. Adopt it without touching the engine, which
        // is still sounding it. With nothing loaded the app opens on the walks selector rather than
        // dropping the listener into an arbitrary walk, matching iOS.
        _current.value = (app as SongitudeApp).loadedExperience
        authoredCurrent = _current.value

        location.onLocation = { coord -> ingestFix(coord) }
        engine.remoteToggle = { play ->
            if (play) {
                location.start(); engine.start(); primeEngineWithCurrentLocation()
            } else {
                engine.stop(); location.stop(); stopSlew()
            }
        }

        // Keep the catalog sorted nearest-first as fixes arrive, and settle any question that was
        // waiting on a position.
        viewModelScope.launch {
            location.location.collect { coord ->
                if (coord == null) return@collect
                _walks.value = CatalogService.sorted(_walks.value, coord)
                val authored = authoredCurrent
                if (pendingRecenter && authored?.map?.startAnchor != null) {
                    pendingRecenter = false
                    applyPlacement(authored)
                }
                if (pendingFarAwayCheck) maybeShowFarAwayCard()
            }
        }
        viewModelScope.launch {
            location.heading.collect { h ->
                if (h == null || !pendingHeadingPlacement) return@collect
                val authored = authoredCurrent ?: return@collect
                if (authored.map.startAnchor == null || location.lastKnownLocation == null) return@collect
                pendingHeadingPlacement = false
                applyPlacement(authored)
            }
        }

        refreshDownloadedIds()
        refreshCatalog()
        location.primeFromCache()
    }

    /** Keep the process-lifetime copy in step, so an Activity restart finds the walk again. */
    private fun rememberLoaded(exp: Experience?) {
        (getApplication() as SongitudeApp).loadedExperience = exp
    }

    fun isDownloaded(id: String) = _downloadedIds.value.contains(id)

    fun refreshDownloadedIds() { _downloadedIds.value = downloader.downloadedIds() }

    fun setAppearance(a: AppAppearance) {
        _appearance.value = a
        prefs.edit().putString(APPEARANCE_KEY, a.key).apply()
    }

    fun refreshCatalog(onDone: (() -> Unit)? = null) {
        _catalogLoading.value = true
        viewModelScope.launch {
            val result = CatalogService.fetchManifest()
            _catalogLoading.value = false
            result.fold(
                onSuccess = { list ->
                    _catalogError.value = null
                    _walks.value = CatalogService.sorted(list, location.lastKnownLocation)
                    processPendingWalk()
                },
                onFailure = { e ->
                    _catalogError.value = e.message ?: "Couldn't load the catalog."
                },
            )
            onDone?.invoke()
        }
    }

    fun loadArtist(id: String) {
        if (_artists.value.containsKey(id) || artistsInFlight.contains(id)) return
        artistsInFlight.add(id)
        viewModelScope.launch {
            val p = CatalogService.fetchArtist(id)
            artistsInFlight.remove(id)
            if (p != null) _artists.value = _artists.value + (id to p)
        }
    }

    // MARK: - Active experience

    fun setCurrent(exp: Experience) {
        // A finished download re-enters this for a walk that is already on screen — the shell went
        // up as soon as map.json landed. That is not the listener choosing a different walk, and it
        // must not retract a card they are mid-way through reading.
        val switchingWalk = _current.value?.id != exp.id
        if (switchingWalk) {
            _introShowings.value = 0
            _showFarAwayCard.value = false
        }
        // Load the *placed* walk, not the authored one. For a transportable walk these differ: the
        // map draws the areas moved onto the listener while the engine would otherwise keep testing
        // against the coordinates they were composed at, so nothing ever sounds and nothing ever
        // highlights. iOS gets away with the authored copy here because its re-placement always
        // fires a moment later; on Android the fix arrives through a StateFlow, which drops a value
        // equal to the one already held — so an identical one-shot fix would never re-place it.
        val placed = anchoredIfPortable(exp)
        _current.value = placed
        rememberLoaded(placed)
        _offset.value = CoordinateOffset.NONE
        engine.load(placed)              // stops current playback
        engine.setOffset(CoordinateOffset.NONE)
        location.stop(); stopSlew()      // switching pauses playback → release GPS and reset slewing
        maybeShowIntroCard()
        if (!_showIntroCard.value && !_showFarAwayCard.value) maybeShowFarAwayCard()
    }

    /** A transportable walk (one carrying a startAnchor) is moved and turned onto the listener the
     *  moment it opens, so the whole composition plays out from wherever they stand, facing wherever
     *  they face. A walk with no anchor is returned untouched. With no fix yet we leave it as
     *  authored rather than guess a position. */
    private fun anchoredIfPortable(exp: Experience): Experience {
        authoredCurrent = exp
        val anchor = exp.map.startAnchor ?: return exp

        // Always chase a fresh fix and heading for a portable walk: a cached one can be stale, or
        // absent on a cold launch, and placing the walk in the wrong city means nothing is ever in
        // range and it plays silently.
        pendingRecenter = true
        if (location.heading.value == null) pendingHeadingPlacement = true
        location.requestOneShotFix()

        val here = location.lastKnownLocation ?: return exp
        val t = WalkTransposition(anchor, here, location.heading.value ?: anchor.heading)
        return Experience(exp.id, exp.directory, exp.map.transposed(t))
    }

    /** Whether the loaded walk ships an exit clip. Without one there is no outro to offer. */
    val currentHasOutro: Boolean get() = !_current.value?.map?.exit.isNullOrEmpty()

    /** True when the loaded walk travels with the listener, so the UI can offer to re-place it. */
    val currentIsPortable: Boolean get() = authoredCurrent?.map?.startAnchor != null

    /** Drop the walk around wherever the listener is standing now. */
    fun recenterPortableWalk() {
        val authored = authoredCurrent ?: return
        if (authored.map.startAnchor == null) return
        pendingRecenter = true
        location.requestOneShotFix()
        applyPlacement(authored)     // immediate, from the best position we already have
    }

    /** Re-place the walk around the listener. Deliberately not [setCurrent]: that reloads the engine,
     *  which stops playback and resets dialogue history. Here only the coordinates change, so the
     *  audio keeps running and simply re-evaluates against the new positions. */
    private fun applyPlacement(authored: Experience) {
        val placed = anchoredIfPortable(authored)
        pendingRecenter = false
        _current.value = placed
        rememberLoaded(placed)
        _placementVersion.value += 1
        engine.updateGeometry(placed)
        primeEngineWithCurrentLocation()
    }

    // MARK: - Intro card

    private fun introKey(id: String) = "introCard.seen.$id"

    fun maybeShowIntroCard() {
        val id = _current.value?.id ?: return
        val last = prefs.getLong(introKey(id), 0L)
        if (last > 0 && nowSeconds() - last < INTRO_WINDOW_SECONDS) return
        _showIntroCard.value = true
        engine.cancelDoneTimer()
    }

    /** Tapping the walk's name in the top bar always brings the card back. */
    fun presentIntroCard() {
        if (_current.value == null) return
        if (!_showIntroCard.value) _introShowings.value += 1
        _showIntroCard.value = true
        engine.cancelDoneTimer()
    }

    fun dismissIntroCard() {
        _current.value?.id?.let { prefs.edit().putLong(introKey(it), nowSeconds().toLong()).apply() }
        _showIntroCard.value = false
        if (engine.isRunning.value) engine.armDoneTimer()
        maybeShowFarAwayCard()
    }

    // MARK: - Far-away card

    private fun farAwayKey(id: String) = "farAwayCard.seen.$id"

    /** How far the listener is from the loaded walk, in miles — null without a walk or a fix. */
    val currentWalkDistanceMiles: Double?
        get() {
            val exp = _current.value ?: return null
            val here = location.location.value ?: location.lastKnownLocation ?: return null
            return GeoUtils.distance(here, exp.map.centerCoord) / 1609.344
        }

    /** Once the walk's own card is out of the way, tell a listener who is nowhere near it that they
     *  won't hear anything from here. Advisory: it never blocks opening the walk. A transportable
     *  walk is exempt — it re-anchors onto wherever they are standing. */
    fun maybeShowFarAwayCard() {
        val exp = _current.value
        if (exp == null || currentIsPortable) { pendingFarAwayCheck = false; return }
        if (_showIntroCard.value) return            // hold; dismissing that card asks again
        val last = prefs.getLong(farAwayKey(exp.id), 0L)
        if (last > 0 && nowSeconds() - last < INTRO_WINDOW_SECONDS) { pendingFarAwayCheck = false; return }
        val here = location.location.value ?: location.lastKnownLocation
        if (here == null) {
            // No position yet: ask for one and decide when it lands, rather than warning on a guess.
            pendingFarAwayCheck = true
            location.requestOneShotFix()
            return
        }
        pendingFarAwayCheck = false
        if (GeoUtils.distance(here, exp.map.centerCoord) <= FAR_AWAY_DISTANCE_M) return
        _showFarAwayCard.value = true
        engine.cancelDoneTimer()
    }

    fun dismissFarAwayCard() {
        pendingFarAwayCheck = false
        _current.value?.id?.let { prefs.edit().putLong(farAwayKey(it), nowSeconds().toLong()).apply() }
        _showFarAwayCard.value = false
        if (engine.isRunning.value) engine.armDoneTimer()
    }

    /** The catalog entry for the active walk, when it came from the server — carries the artistId
     *  that a bundle's map.json doesn't have. */
    val currentRemoteWalk: RemoteWalk?
        get() = _current.value?.id?.let { id -> _walks.value.firstOrNull { it.id == id } }

    // MARK: - Remote walks

    fun openRemote(walk: RemoteWalk) {
        activeWalkRequest = walk.id
        // Silence the walk they're leaving straight away, or the previous one keeps playing through
        // the download of the new one.
        if (_current.value?.id != walk.id) { engine.stop(); location.stop(); stopSlew() }

        // Only reuse the cache when it matches the published revision; otherwise fall through to the
        // downloader, which rewrites map.json and fetches anything missing.
        if (downloader.isUpToDate(walk)) {
            downloader.cachedExperience(walk.id)?.let { exp ->
                _downloadingWalkId.value = null
                setCurrent(exp)
                presentIntroCard()
                return
            }
        }
        val previous = _current.value
        _downloadingWalkId.value = walk.id
        _downloadProgress.value = 0.0
        _catalogError.value = null

        downloadJob?.cancel()
        downloadJob = viewModelScope.launch {
            val result = downloader.download(
                walk,
                mapReady = { map ->
                    if (activeWalkRequest == walk.id) {
                        // map.json is a few KB: recenter and retitle now rather than after the audio.
                        showWalkShell(Experience(walk.id, downloader.cacheDir(walk.id), map))
                    }
                },
                progress = { p -> if (activeWalkRequest == walk.id) _downloadProgress.value = p },
            )
            refreshDownloadedIds()            // the files landed either way
            // Superseded: the listener has opened something else since. Leave their view alone.
            if (activeWalkRequest != walk.id) return@launch
            _downloadingWalkId.value = null
            result.fold(
                onSuccess = { exp -> setCurrent(exp) },   // now the audio exists → load the engine
                onFailure = { e ->
                    _catalogError.value = "Download failed: ${e.message ?: "unknown error"}"
                    if (previous != null) setCurrent(previous) else _current.value = null
                },
            )
        }
    }

    /** Put a walk on screen before its audio exists: map, title and re-centering only. The engine is
     *  deliberately not loaded — there is nothing yet for it to play. */
    private fun showWalkShell(exp: Experience) {
        if (_current.value?.id != exp.id) {
            _introShowings.value = 0
            _showFarAwayCard.value = false
        }
        _current.value = anchoredIfPortable(exp)
        rememberLoaded(_current.value)
        _offset.value = CoordinateOffset.NONE
        engine.setOffset(CoordinateOffset.NONE)
        location.stop(); stopSlew()
        presentIntroCard()
    }

    /** Delete a downloaded walk's local files. Uninstalling the loaded walk also unloads it. */
    fun deleteDownloaded(id: String) {
        downloader.deleteCache(id, engine)
        val wasCurrent = _current.value?.id == id
        if (activeWalkRequest == id) activeWalkRequest = null
        if (wasCurrent) {
            _current.value = null
            rememberLoaded(null)
            _showIntroCard.value = false
            _showFarAwayCard.value = false
            engine.stop(); location.stop(); stopSlew()
        }
        refreshDownloadedIds()
    }

    // MARK: - Deep link

    fun handleDeepLink(uri: Uri) {
        val id = uri.getQueryParameter("walk")?.takeIf { it.isNotEmpty() } ?: return
        if (!_hasOnboarded.value) { pendingWalkId = id; return }
        openWalk(id)
    }

    fun openWalk(id: String) {
        downloader.cachedExperience(id)?.let { pendingWalkId = null; setCurrent(it); return }
        val w = _walks.value.firstOrNull { it.id == id }
        if (w != null) { pendingWalkId = null; openRemote(w) }
        else { pendingWalkId = id; refreshCatalog() }
    }

    private fun processPendingWalk() {
        if (!_hasOnboarded.value) return
        val id = pendingWalkId ?: return
        _walks.value.firstOrNull { it.id == id }?.let { pendingWalkId = null; openRemote(it) }
    }

    // MARK: - Onboarding and permissions

    /**
     * Wipe every trace of local state and land back on the first-run screen.
     *
     * Android, like iOS, does not let an app revoke its own location grant — that lives in system
     * Settings. After a reset the onboarding screen reappears, but a previously granted permission
     * stays granted and the button falls straight through to "authorized".
     */
    fun resetEverything() {
        engine.stop(); location.stop(); stopSlew()
        downloader.deleteAllCaches()
        prefs.edit().clear().apply()
        _offset.value = CoordinateOffset.NONE
        engine.setOffset(CoordinateOffset.NONE)
        _experiences.value = ExperienceLibrary.loadAll(ctx)
        _current.value = null
        rememberLoaded(null)
        _showIntroCard.value = false
        _showFarAwayCard.value = false
        _showPermissionDeniedAlert.value = false
        _appearance.value = AppAppearance.SYSTEM
        _hasOnboarded.value = false
        _downloadedIds.value = emptySet()
        _resetToken.value += 1
        refreshCatalog()
    }

    /** Shown once per install, at the same moment the onboarding screen first appears. Read
     *  straight from prefs so a returning launch never flashes a frame of splash. */
    val splashSeen: Boolean get() = prefs.getBoolean(SPLASH_KEY, false)
    fun markSplashSeen() { prefs.edit().putBoolean(SPLASH_KEY, true).apply() }

    fun completeOnboarding() {
        _hasOnboarded.value = true
        prefs.edit().putBoolean(ONBOARD_KEY, true).apply()
        processPendingWalk()
    }

    fun dismissPermissionAlert() { _showPermissionDeniedAlert.value = false }

    fun onPermissionResult() {
        location.refreshAuthorization()
        // The provider usually already knows where the phone is; take that now so the first press
        // of play has a position to work from.
        location.primeFromCache()
    }

    // MARK: - Playback

    fun togglePlayback() {
        if (!location.isAuthorized) { _showPermissionDeniedAlert.value = true; return }
        if (engine.isRunning.value) {
            engine.stop(); location.stop(); stopSlew()
        } else {
            location.start(); engine.start(); primeEngineWithCurrentLocation()
        }
    }

    /**
     * Evaluate the whole walk against wherever the listener is standing, right now.
     *
     * Pressing play must sound the areas underfoot immediately rather than waiting for the location
     * stream to produce its first update — that wait was silence, and it was indistinguishable from
     * the app being broken. So this primes from the best position already known, and separately asks
     * for a fresh fix, re-evaluating again when it lands.
     */
    private fun primeEngineWithCurrentLocation() {
        val here = location.location.value ?: location.lastKnownLocation
        if (here != null) {
            virtualCoord = here      // slew starts from here on the next fix
            engine.updateLocation(here)
        }
        // A fix straight from the hardware, however stale the cached one was. Adopted directly
        // rather than slewed: this is the listener saying "start here", not a position drifting.
        location.requestImmediateFix { fresh ->
            virtualCoord = fresh
            engine.updateLocation(fresh)
        }
    }

    // MARK: - GPS slewing

    /** Ease the virtual position toward each new fix in ~0.2 s steps of at most 5 m, so a GPS jump
     *  can't skip over a zone. Steps are capped so a genuine fast move still catches up within a
     *  few seconds. */
    private fun ingestFix(coord: LatLngD) {
        val from = virtualCoord
        if (from == null) {                      // first fix — adopt it directly
            virtualCoord = coord
            engine.updateLocation(coord)
            return
        }
        slewJob?.cancel()
        val steps = max(1, min(25, ceil(GeoUtils.distance(from, coord) / 5.0).toInt()))
        slewJob = viewModelScope.launch {
            for (step in 1..steps) {
                delay(200)
                val f = step.toDouble() / steps
                val c = LatLngD(
                    from.lat + (coord.lat - from.lat) * f,
                    from.lng + (coord.lng - from.lng) * f,
                )
                virtualCoord = c
                engine.updateLocation(c)
            }
            slewJob = null
        }
    }

    private fun stopSlew() {
        slewJob?.cancel(); slewJob = null; virtualCoord = null
    }

    // MARK: - Debug: re-center map over me

    fun recenterOnMe() {
        val exp = _current.value ?: return
        val here = location.location.value ?: location.lastKnownLocation ?: return
        val newOffset = CoordinateOffset.recentering(exp.map.centerCoord, here)
        _offset.value = newOffset
        engine.setOffset(newOffset)
        primeEngineWithCurrentLocation()
    }

    fun clearRecenter() {
        _offset.value = CoordinateOffset.NONE
        engine.setOffset(CoordinateOffset.NONE)
        primeEngineWithCurrentLocation()
    }

    private fun nowSeconds(): Double = System.currentTimeMillis() / 1000.0

    override fun onCleared() {
        super.onCleared()
        // Deliberately does NOT stop the engine: the walk keeps playing with the screen off, which
        // is the entire point. The foreground service owns that lifetime now.
    }
}
