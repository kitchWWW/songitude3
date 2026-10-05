package com.brianellissound.songitude

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.compose.BackHandler
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import androidx.lifecycle.viewmodel.compose.viewModel
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.ui.Brand
import com.brianellissound.songitude.ui.MapScreen
import com.brianellissound.songitude.ui.SongitudeTheme
import com.brianellissound.songitude.ui.screens.AboutScreen
import com.brianellissound.songitude.ui.screens.FirstRunScreen
import com.brianellissound.songitude.ui.screens.FirstRunStep
import com.brianellissound.songitude.ui.screens.SettingsScreen
import com.brianellissound.songitude.ui.screens.SoundwalksScreen
import com.brianellissound.songitude.ui.screens.WalkDetailScreen

/** Logcat tag for navigation — every screen change, so a report of "back went to the wrong page"
 *  can be read straight off the log. */
private const val NAV_TAG = "ChromicNav"

/** One step of the browser stack, above the About root. */
private sealed interface Route {
    data object Walks : Route
    data class Walk(val walk: RemoteWalk) : Route
}

/**
 * Where the listener is in the app, held for the life of the **process** rather than the Activity.
 *
 * Android destroys the Activity while a walk plays with the screen off (see `android/LIFECYCLE.md`,
 * L10), and a recreated Activity is not a fresh start: it must come back to the same page, and the
 * time spent away must still count. An `object` lives exactly as long as the process — the same
 * lifetime as the engine and the loaded walk on [SongitudeApp] — and a process death starts it over,
 * which is what makes that a cold start and shows the welcome. The iOS twin keeps the same state
 * as `@State` on `SplashRootView`, where the view's lifetime already is the process's.
 */
private object HomeSession {
    /** Home opens on Soundwalks with About underneath it, so the cloud is an ordinary pop. */
    val LANDING: List<Route> = listOf(Route.Walks)

    /** True from process start until the welcome (and the location page, if shown) is passed. */
    var welcoming by mutableStateOf(true)
    var path by mutableStateOf(LANDING)
    var showMap by mutableStateOf(false)
    /** The walk whose map was last shown for its arrival, so the map opens once when a walk becomes
     *  current (Start, a deep link) and not again every time home is composed. */
    var announcedWalkId: String? = null

    /** `elapsedRealtime` at the last `onStop` (it counts deep sleep, which the screen-off case is);
     *  null while in the foreground. */
    private var stoppedAt: Long? = null
    /** Whether a walk was under way at that moment. Sampled on the way out as well as on return,
     *  because `reconcileOnForeground` may settle a dead mixer into "paused" as we come back, and a
     *  walk that was playing when the phone was pocketed must count as under way regardless. */
    private var walkActiveWhenStopped = false

    /** A walk is under way while it plays — in the background too — or while its map is on screen,
     *  playing or paused. Either way the listener is coming back to the walk, not to the app. */
    private fun walkUnderWay(app: SongitudeApp) = app.engine.isRunning.value || showMap

    fun leftForeground(app: SongitudeApp) {
        stoppedAt = SystemClock.elapsedRealtime()
        walkActiveWhenStopped = walkUnderWay(app)
    }

    /** Back after [Brand.RESUME_WINDOW_MS] with no walk under way: start over at the welcome.
     *  Anything shorter — or any absence at all mid-walk — resumes exactly where it was. */
    fun returnedToForeground(app: SongitudeApp) {
        val since = stoppedAt ?: return
        stoppedAt = null
        val away = SystemClock.elapsedRealtime() - since
        if (away <= Brand.RESUME_WINDOW_MS || walkActiveWhenStopped || walkUnderWay(app) || welcoming) return
        Log.i(NAV_TAG, "back after ${away / 1000}s with no walk under way → welcome")
        welcoming = true
        path = LANDING
        showMap = false
    }

    /** The welcome is over. Home lands on Soundwalks — also after "Reset app", which can leave the
     *  old path and an open map behind it. A loaded-but-idle walk stays loaded. */
    fun enterHome() {
        welcoming = false
        path = LANDING
        showMap = false
    }
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // Hand back the launch theme. Its window background is the splash picture, and that sits
        // behind every window in the app — leave it in place and it flashes through every sheet,
        // screen change and transition.
        setTheme(R.style.Theme_Songitude)
        super.onCreate(savedInstanceState)
        setContent {
            val app: AppState = viewModel()
            val appearance by app.appearance.collectAsState()

            SongitudeTheme(appearance) {
                Root(app, intent?.data)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        HomeSession.returnedToForeground(application as SongitudeApp)
    }

    override fun onStop() {
        super.onStop()
        HomeSession.leftForeground(application as SongitudeApp)
    }

    override fun onResume() {
        super.onResume()
        val app = application as SongitudeApp
        // Permission can change in system Settings while we are away.
        app.location.refreshAuthorization()
        // And the mixer may have died while we were gone; make the button tell the truth rather
        // than reading "pause" over silence.
        app.engine.reconcileOnForeground()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
}

@Composable
private fun Root(app: AppState, deepLink: Uri?) {
    val hasOnboarded by app.hasOnboarded.collectAsState()
    val resetToken by app.resetToken.collectAsState()
    val showPermissionAlert by app.showPermissionDeniedAlert.collectAsState()
    val context = LocalContext.current

    LaunchedEffect(deepLink) { deepLink?.let { app.handleDeepLink(it) } }

    // Keyed on the reset token so "Reset app" starts the first-run scene over from the landing.
    // The welcome shows on every cold start and after a long absence, not only until onboarding.
    key(resetToken) {
        if (!hasOnboarded || HomeSession.welcoming) FirstRun(app) else HomeRoot(app)
    }

    if (showPermissionAlert) {
        AlertDialog(
            onDismissRequest = { app.dismissPermissionAlert() },
            title = { Text("Location is off") },
            // A second route to the location grant for anyone who chose "Not now" in onboarding, so it
            // carries the full Prominent Disclosure too: what is used, how, with the screen locked,
            // and that it is never shared. Play rejected 1.0.1 for vaguer wording.
            text = {
                Text("${Brand.NAME} uses your location data to choose what you hear: your position decides " +
                    "which sounds play and how loud, including while a walk plays with your screen " +
                    "locked or the phone in your pocket. Your location stays on this phone and is " +
                    "never uploaded, stored or shared.\n\n" +
                    "To start a walk, turn on location for ${Brand.NAME} in system Settings.")
            },
            confirmButton = {
                TextButton(onClick = {
                    app.dismissPermissionAlert()
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", context.packageName, null)
                        }
                    )
                }) { Text("Open Settings") }
            },
            dismissButton = {
                TextButton(onClick = { app.dismissPermissionAlert() }) { Text("Not now") }
            },
        )
    }
}

/**
 * The welcome: landing → location → (Android 13+) notification → home. Shown on every cold start,
 * and after a long absence ([HomeSession.returnedToForeground]). The location page is skipped when
 * fine location is already granted, and the notification page when notifications already are. The
 * permission plumbing is Songitude's, untouched; only the screens changed (`FirstRunScreen`).
 */
@Composable
private fun FirstRun(app: AppState) {
    val context = LocalContext.current
    var step by rememberSaveable { mutableStateOf(FirstRunStep.LANDING) }
    fun granted(permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    // Onboarding is still recorded (it gates deep links, and a reset clears it), then home.
    val finish = { app.completeOnboarding(); HomeSession.enterHome() }
    // True from the moment Continue is pressed until the system has finished with us. The screen
    // holds still for the whole of that.
    var awaitingSystemUi by remember { mutableStateOf(false) }

    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.i(NAV_TAG, "notification permission result: $granted → home")
        awaitingSystemUi = false
        finish()
    }

    // On anything below Android 13 there is no runtime notification permission, so the third
    // step has nothing to ask for and is skipped rather than shown for nothing — as it is when a
    // later launch comes back through the location page with notifications already allowed.
    val advancePastLocation = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !granted(Manifest.permission.POST_NOTIFICATIONS)) {
            Log.i(NAV_TAG, "location done → notification page")
            step = FirstRunStep.NOTIFICATION
        } else {
            Log.i(NAV_TAG, "location done, nothing to ask about notifications → home")
            finish()
        }
    }

    // Foreground location only. The walk runs in a location-type foreground service, which keeps
    // GPS flowing with the screen off on this grant alone; see the manifest for why there is no
    // background request.
    val foregroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        Log.i(NAV_TAG, "foreground location result: $granted")
        app.onPermissionResult()
        awaitingSystemUi = false
        advancePastLocation()
    }

    FirstRunScreen(
        step = step,
        busy = awaitingSystemUi,
        onBegin = {
            // A grant needs no second pitch on every launch. Coarse-only still gets the page: a walk
            // needs fine location to tell one area from the next.
            if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
                Log.i(NAV_TAG, "landing, location already granted → home")
                finish()
            } else {
                Log.i(NAV_TAG, "landing → location page")
                step = FirstRunStep.LOCATION
            }
        },
        onContinue = {
            awaitingSystemUi = true
            when (step) {
                FirstRunStep.LOCATION -> foregroundLauncher.launch(
                    arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                )
                else -> notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
        },
        onNotNow = {
            Log.i(NAV_TAG, "not now on $step")
            when (step) {
                FirstRunStep.LOCATION -> advancePastLocation()
                else -> finish()
            }
        },
    )
}

/**
 * Home: the About → Soundwalks → walk stack, with the map presented over it — the opposite way up
 * from Songitude, where the map is the root and the list a cover. The map is where Start takes you,
 * and leaving it returns you to the page you started from, walk still playing.
 *
 * It opens on Soundwalks with About underneath ([HomeSession.LANDING]) rather than pushing About
 * from the list: the cloud is then an ordinary pop, About's "Soundwalks" button the way back, and
 * the artist's name anywhere still goes to About by clearing the path. The state is
 * [HomeSession]'s, so a recreated Activity comes back to the same page.
 *
 * Plain state rather than a nav graph, as before. System Back walks it: closes Settings, then
 * leaves the map, then pops the stack, then leaves the app.
 */
@Composable
private fun HomeRoot(app: AppState) {
    val current by app.current.collectAsState()
    val walks by app.walks.collectAsState()
    var path by HomeSession::path
    var showMap by HomeSession::showMap
    var showSettings by remember { mutableStateOf(false) }

    // A QR deep link names a walk — even one that arrived during the welcome — and the map is what
    // to show. Only for a walk not already announced: a recreated Activity adopting the playing
    // walk keeps whatever page the session was on, and starting over after a long absence doesn't
    // bounce a loaded-but-idle walk's map straight back up. Start goes through here too, harmlessly.
    LaunchedEffect(current?.id) {
        val id = current?.id ?: return@LaunchedEffect
        if (id != HomeSession.announcedWalkId) { HomeSession.announcedWalkId = id; showMap = true }
    }

    /** The current walk's page, when the catalog knows it; otherwise the list. */
    fun walkPath(): List<Route> {
        val w = walks.firstOrNull { it.id == current?.id }
        return if (w != null) listOf(Route.Walks, Route.Walk(w)) else listOf(Route.Walks)
    }
    fun start(walk: RemoteWalk) {
        // Already loaded: reloading would stop playback, so just return to its map.
        if (current?.id != walk.id) app.openRemote(walk)
        showMap = true
    }

    LaunchedEffect(path, showMap, showSettings) {
        Log.i(NAV_TAG, "About" + path.joinToString("") { r ->
            when (r) { Route.Walks -> " > Soundwalks"; is Route.Walk -> " > ${r.walk.id}" }
        } + (if (showMap) " [map]" else "") + (if (showSettings) " [settings]" else ""))
    }

    BackHandler(enabled = showSettings || showMap || path.isNotEmpty()) {
        when {
            showSettings -> showSettings = false
            showMap -> showMap = false
            else -> path = path.dropLast(1)
        }
    }

    Box(Modifier.fillMaxSize()) {
        when (val top = path.lastOrNull()) {
            null -> AboutScreen(app, onSoundwalks = { path = listOf(Route.Walks) })
            Route.Walks -> SoundwalksScreen(
                app = app,
                onOpen = { w -> path = path + Route.Walk(w) },
                onArtist = { path = emptyList() },
                onBack = { path = path.dropLast(1) },
            )
            is Route.Walk -> WalkDetailScreen(
                app = app, walk = top.walk,
                onStart = { start(top.walk) },
                onArtist = { path = emptyList() },
                onBack = { path = path.dropLast(1) },
            )
        }
        if (showMap) {
            MapScreen(
                app = app,
                onOpenSettings = { showSettings = true },
                onShowWalk = { path = walkPath(); showMap = false },
                onBrowse = { path = listOf(Route.Walks); showMap = false },
                onOpenArtist = { _, _ -> path = emptyList(); showMap = false },
            )
        }
        if (showSettings) SettingsScreen(app = app, onClose = { showSettings = false })
    }
}
