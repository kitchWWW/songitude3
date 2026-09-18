package com.brianellissound.songitude

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
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
    key(resetToken) {
        if (!hasOnboarded) FirstRun(app) else HomeRoot(app)
    }

    if (showPermissionAlert) {
        AlertDialog(
            onDismissRequest = { app.dismissPermissionAlert() },
            title = { Text("Location is off") },
            text = {
                Text("${Brand.NAME} needs your location to know which part of the music to play. " +
                    "You can turn it on in system Settings.")
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
 * The first launch: landing → location → (Android 13+) notification → home. The permission
 * plumbing is Songitude's, untouched; only the screens changed (`FirstRunScreen`).
 */
@Composable
private fun FirstRun(app: AppState) {
    var step by rememberSaveable { mutableStateOf(FirstRunStep.LANDING) }
    // True from the moment Continue is pressed until the system has finished with us. The screen
    // holds still for the whole of that.
    var awaitingSystemUi by remember { mutableStateOf(false) }

    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.i(NAV_TAG, "notification permission result: $granted → home")
        awaitingSystemUi = false
        app.completeOnboarding()
    }

    // On anything below Android 13 there is no runtime notification permission, so the third
    // step has nothing to ask for and is skipped rather than shown for nothing.
    val advancePastLocation = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Log.i(NAV_TAG, "location done → notification page")
            step = FirstRunStep.NOTIFICATION
        } else {
            Log.i(NAV_TAG, "location done, no notification permission on this Android → home")
            app.completeOnboarding()
        }
    }

    // Foreground location first. Background location has to be a separate request, and Android only
    // offers it once the foreground grant exists — and on Android 11+ it opens a full Settings page
    // rather than a dialog, which is why advancing has to wait for *this* to come back.
    val backgroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        Log.i(NAV_TAG, "background location result: $granted")
        app.onPermissionResult()
        awaitingSystemUi = false
        advancePastLocation()
    }

    val foregroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        app.onPermissionResult()
        val fine = granted[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            granted[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        Log.i(NAV_TAG, "foreground location result: $granted")
        if (fine && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Stay on this screen: the background request is about to open Settings, and advancing
            // now would render the next screen behind it, visible the moment Settings is dismissed
            // — or, worse, glimpsed before it even appears.
            backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        } else {
            awaitingSystemUi = false
            advancePastLocation()
        }
    }

    FirstRunScreen(
        step = step,
        busy = awaitingSystemUi,
        onBegin = { Log.i(NAV_TAG, "landing → location page"); step = FirstRunStep.LOCATION },
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
                else -> app.completeOnboarding()
            }
        },
    )
}

/**
 * Home: the About → Soundwalks → walk stack, with the map presented over it — the opposite way up
 * from Songitude, where the map is the root and the list a cover. The map is where Start takes you,
 * and leaving it returns you to the page you started from, walk still playing.
 *
 * Plain state rather than a nav graph, as before. System Back walks it: closes Settings, then
 * leaves the map, then pops the stack, then leaves the app.
 */
@Composable
private fun HomeRoot(app: AppState) {
    val current by app.current.collectAsState()
    val walks by app.walks.collectAsState()
    var path by remember { mutableStateOf<List<Route>>(emptyList()) }
    var showMap by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    // A QR deep link names a walk — or the Activity comes back to a walk still playing on the
    // Application — and the map is what to show. Start goes through here too, harmlessly.
    LaunchedEffect(current?.id) { if (current != null) showMap = true }

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
