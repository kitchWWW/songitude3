package com.brianellissound.songitude.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.R
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.DialogueColors
import com.brianellissound.songitude.model.LatLngD
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.maps.android.compose.*

/**
 * The player screen: a full-bleed map with the sound areas overlaid, a gear in the top-left, and a
 * big play/pause at the bottom that toggles the whole rendering engine.
 *
 * Ported from ios/.../Views/ContentView.swift, including the rule that the transport is hidden
 * entirely when no walk is loaded — a visible control that cannot act reads as a broken one.
 */
@Composable
fun MapScreen(
    app: AppState,
    onOpenSettings: () -> Unit,
    onOpenBrowser: () -> Unit,
    onOpenArtist: (String, String) -> Unit,
) {
    val current by app.current.collectAsState()
    val offset by app.offset.collectAsState()
    val sounding by app.engine.soundingShapeIds.collectAsState()
    val dialogueStates by app.engine.dialogueStates.collectAsState()
    val isRunning by app.engine.isRunning.collectAsState()
    val canEnd by app.engine.canEndSession.collectAsState()
    val downloadingId by app.downloadingWalkId.collectAsState()
    val progress by app.downloadProgress.collectAsState()
    val showIntro by app.showIntroCard.collectAsState()
    val showFarAway by app.showFarAwayCard.collectAsState()
    val placement by app.placementVersion.collectAsState()
    val appearance by app.appearance.collectAsState()
    val here by app.location.location.collectAsState()

    val dark = isDarkTheme(appearance)
    val context = LocalContext.current

    val exp = current
    val mapCenter = exp?.map?.centerCoord ?: here ?: LatLngD(39.5, -98.35)
    val zoom = (exp?.map?.zoom ?: 15.0).toFloat()

    val cameraPositionState = rememberCameraPositionState {
        position = CameraPosition.fromLatLngZoom(LatLng(mapCenter.lat, mapCenter.lng), zoom)
    }

    // Placement is part of the identity: a re-anchored walk has the same id but different
    // coordinates, so the camera has to follow it even though nothing else changed.
    LaunchedEffect(exp?.id, placement, mapCenter.lat, mapCenter.lng) {
        cameraPositionState.position =
            CameraPosition.fromLatLngZoom(LatLng(mapCenter.lat, mapCenter.lng), zoom)
    }

    Box(Modifier.fillMaxSize()) {
        GoogleMap(
            modifier = Modifier.fillMaxSize(),
            cameraPositionState = cameraPositionState,
            properties = MapProperties(
                isMyLocationEnabled = app.location.isAuthorized,
                mapStyleOptions = MapStyleOptions.loadRawResourceStyle(
                    context,
                    if (dark) R.raw.map_style_dark else R.raw.map_style_light,
                ),
            ),
            uiSettings = MapUiSettings(
                zoomControlsEnabled = false,
                mapToolbarEnabled = false,
                myLocationButtonEnabled = false,
                tiltGesturesEnabled = false,
            ),
        ) {
            if (exp != null) {
                SoundShapeOverlays(
                    shapes = exp.map.shapes,
                    offset = offset,
                    soundingIds = sounding,
                    dialogueStates = dialogueStates,
                    dialogueColors = exp.map.dialoguePalette,
                    fuzzy = exp.map.isFuzzy,
                )
                RouteOverlays(exp.map.drawableRoutes, offset)
                MapLabelOverlays(exp, offset)
            }
        }

        // Top bar: gear · walk title (opens the card or the browser) · browse
        Row(
            Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassCircleButton(onClick = onOpenSettings) {
                Icon(Icons.Filled.Settings, contentDescription = "Settings")
            }
            Spacer(Modifier.weight(1f))
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
                tonalElevation = 3.dp,
                onClick = { if (exp != null) app.presentIntroCard() else onOpenBrowser() },
            ) {
                Row(
                    Modifier.height(44.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        exp?.displayName ?: "Songitude",
                        style = MaterialTheme.typography.titleMedium,
                        maxLines = 1,
                    )
                    Spacer(Modifier.width(6.dp))
                    Icon(
                        if (exp != null) Icons.Filled.Info else Icons.Filled.KeyboardArrowDown,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp),
                    )
                }
            }
            Spacer(Modifier.weight(1f))
            GlassCircleButton(onClick = onOpenBrowser) {
                Icon(Icons.Filled.Layers, contentDescription = "Browse soundwalks")
            }
        }

        // Transport. Only offered once a walk is loaded: with nothing loaded there is no clip to
        // start and nowhere to skip to, and the map is just a map.
        if (exp != null) {
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .navigationBarsPadding()
                    .padding(bottom = 28.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                if (isRunning && canEnd && app.currentHasOutro) {
                    Surface(
                        shape = RoundedCornerShape(24.dp),
                        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.9f),
                        onClick = { app.engine.endSession() },
                    ) {
                        Text(
                            "Play Outro",
                            Modifier.padding(horizontal = 18.dp, vertical = 14.dp),
                            style = MaterialTheme.typography.titleSmall,
                        )
                    }
                }
                Row(
                    horizontalArrangement = Arrangement.spacedBy(20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    SkipButton(-RenderEngine.SKIP_INTERVAL_SECONDS, isRunning) { app.engine.skip(it) }
                    PlayButton(
                        isRunning = isRunning,
                        downloading = downloadingId != null,
                        progress = progress,
                    ) {
                        if (showIntro) app.dismissIntroCard()
                        app.togglePlayback()
                    }
                    SkipButton(RenderEngine.SKIP_INTERVAL_SECONDS, isRunning) { app.engine.skip(it) }
                }
            }
        }

        if (showIntro && exp != null) {
            WalkIntroCard(app = app, experience = exp, onOpenArtist = onOpenArtist)
        } else if (showFarAway && exp != null) {
            FarAwayCard(
                walkName = exp.displayName,
                distanceMiles = app.currentWalkDistanceMiles,
                onBrowse = { app.dismissFarAwayCard(); onOpenBrowser() },
                onDismiss = { app.dismissFarAwayCard() },
            )
        }
    }
}

@Composable
private fun GlassCircleButton(onClick: () -> Unit, content: @Composable () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
        tonalElevation = 3.dp,
        onClick = onClick,
        modifier = Modifier.size(44.dp),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { content() }
    }
}

/**
 * Back / forward 15 seconds. Always present rather than appearing with playback: holding their
 * place either side keeps the play button from moving under the thumb. With nothing playing they
 * simply go quiet and stop taking taps.
 */
@Composable
private fun SkipButton(delta: Double, live: Boolean, onSkip: (Double) -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = if (live) 0.85f else 0.35f),
        onClick = { if (live) onSkip(delta) },
        modifier = Modifier.size(56.dp),
    ) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            // One icon mirrored, so back and forward read as a pair.
            Icon(
                Icons.Filled.Replay,
                contentDescription = if (delta < 0) "Back 15 seconds" else "Forward 15 seconds",
                modifier = if (delta < 0) Modifier.size(24.dp) else Modifier.size(24.dp).rotate(180f),
                tint = MaterialTheme.colorScheme.onSurface.copy(alpha = if (live) 1f else 0.35f),
            )
        }
    }
}

/** The big play/pause. While a walk downloads it shows progress instead — there is nothing to play
 *  until that completes, so the tap is swallowed rather than the button dimmed. */
@Composable
private fun PlayButton(isRunning: Boolean, downloading: Boolean, progress: Double, onClick: () -> Unit) {
    val fill = if (downloading) Color(0xFF5C6169) else MaterialTheme.colorScheme.primary
    Box(contentAlignment = Alignment.Center) {
        Surface(
            shape = CircleShape,
            color = fill,
            shadowElevation = 12.dp,
            onClick = { if (!downloading) onClick() },
            modifier = Modifier.size(84.dp),
        ) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                if (downloading) {
                    Text(
                        "Downloading",
                        color = Color.White,
                        fontSize = 13.sp,
                        maxLines = 1,
                    )
                } else {
                    Icon(
                        if (isRunning) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                        contentDescription = if (isRunning) "Pause" else "Play",
                        tint = Color.White,
                        modifier = Modifier.size(40.dp),
                    )
                }
            }
        }
        if (downloading) {
            CircularProgressIndicator(
                progress = { progress.toFloat().coerceIn(0.04f, 1f) },
                modifier = Modifier.size(100.dp),
                strokeWidth = 6.dp,
                color = Color.White,
                trackColor = fill,
            )
        }
    }
}
