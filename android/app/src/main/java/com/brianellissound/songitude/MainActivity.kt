package com.brianellissound.songitude

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.viewmodel.compose.viewModel
import com.brianellissound.songitude.ui.MapScreen
import com.brianellissound.songitude.ui.SongitudeTheme
import com.brianellissound.songitude.ui.screens.ArtistPageScreen
import com.brianellissound.songitude.ui.screens.LocationOnboarding
import com.brianellissound.songitude.ui.screens.NotificationOnboarding
import com.brianellissound.songitude.ui.screens.SettingsScreen
import com.brianellissound.songitude.ui.screens.SplashScreen
import com.brianellissound.songitude.ui.screens.WalksBrowserScreen

/** Where the UI currently is. Plain state rather than a nav graph: the app is one screen with a
 *  few full-covers over it, exactly as on iOS. */
private sealed interface Route {
    data object Map : Route
    data object Browser : Route
    data object Settings : Route
    data class Artist(val id: String, val name: String) : Route
}

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
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
        // Permission can change in system Settings while we are away.
        (application as SongitudeApp).location.refreshAuthorization()
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
    val current by app.current.collectAsState()
    val context = LocalContext.current

    var splashDone by rememberSaveable(resetToken) { mutableStateOf(false) }
    var route by remember { mutableStateOf<Route>(Route.Map) }
    var didAutoOpenBrowser by remember { mutableStateOf(false) }

    // Foreground location first. Background location has to be a separate request, and Android only
    // offers it once the foreground grant exists.
    val backgroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { app.onPermissionResult() }

    var onboardStep by rememberSaveable { mutableStateOf(0) }

    val notificationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { app.completeOnboarding() }

    // On anything below Android 13 there is no runtime notification permission, so the second
    // onboarding screen has nothing to ask for and is skipped rather than shown for nothing.
    val advancePastLocation = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) onboardStep = 1
        else app.completeOnboarding()
    }

    val foregroundLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { granted ->
        app.onPermissionResult()
        val fine = granted[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
            granted[Manifest.permission.ACCESS_COARSE_LOCATION] == true
        if (fine && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            backgroundLauncher.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        }
        advancePastLocation()
    }

    LaunchedEffect(deepLink) { deepLink?.let { app.handleDeepLink(it) } }


    // Nothing loaded yet → go straight to the selector, guarded so closing the browser doesn't
    // immediately reopen it, and so a deep link already naming a walk isn't covered by the list.
    LaunchedEffect(current, hasOnboarded, splashDone) {
        if (hasOnboarded && splashDone && current == null && !app.isOpeningWalk && !didAutoOpenBrowser) {
            didAutoOpenBrowser = true
            route = Route.Browser
        }
    }

    when {
        !splashDone -> SplashScreen(onDone = { splashDone = true })
        !hasOnboarded -> when (onboardStep) {
            0 -> LocationOnboarding(
                onContinue = {
                    foregroundLauncher.launch(
                        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
                    )
                },
                onNotNow = { advancePastLocation() },
            )
            else -> NotificationOnboarding(
                onContinue = { notificationLauncher.launch(Manifest.permission.POST_NOTIFICATIONS) },
                onNotNow = { app.completeOnboarding() },
            )
        }
        else -> when (val r = route) {
            is Route.Map -> MapScreen(
                app = app,
                onOpenSettings = { route = Route.Settings },
                onOpenBrowser = { route = Route.Browser },
                onOpenArtist = { id, name -> route = Route.Artist(id, name) },
            )
            is Route.Browser -> WalksBrowserScreen(
                app = app,
                onClose = { route = Route.Map },
                onOpenArtist = { id, name -> route = Route.Artist(id, name) },
            )
            is Route.Settings -> SettingsScreen(app = app, onClose = { route = Route.Map })
            is Route.Artist -> ArtistPageScreen(
                app = app,
                artistId = r.id,
                fallbackName = r.name,
                onBack = { route = Route.Map },
                onOpenWalk = { w -> app.openRemote(w); route = Route.Map },
            )
        }
    }

    if (showPermissionAlert) {
        AlertDialog(
            onDismissRequest = { app.dismissPermissionAlert() },
            title = { Text("Location is off") },
            text = {
                Text("Songitude needs your location to know which part of the music to play. " +
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
