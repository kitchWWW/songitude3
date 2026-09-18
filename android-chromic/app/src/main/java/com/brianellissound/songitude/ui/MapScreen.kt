package com.brianellissound.songitude.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.zIndex
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.R
import com.brianellissound.songitude.audio.RenderEngine
import com.brianellissound.songitude.data.DownloadPhase
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.DialogueColors
import com.brianellissound.songitude.location.SongitudeLocationManager
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
    /** Leave the map for the walk's own page / for the list. The walk keeps playing either way. */
    onShowWalk: () -> Unit,
    onBrowse: () -> Unit,
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
    val downloadPhase by app.downloadPhase.collectAsState()
    val showIntro by app.showIntroCard.collectAsState()
    val showFarAway by app.showFarAwayCard.collectAsState()
    val placement by app.placementVersion.collectAsState()
    val appearance by app.appearance.collectAsState()
    val here by app.location.location.collectAsState()
    val auth by app.location.authorization.collectAsState()
    val locationAuthorized = auth == SongitudeLocationManager.Authorization.WHEN_IN_USE ||
        auth == SongitudeLocationManager.Authorization.ALWAYS

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
                // Derived from the observed authorization, not a plain getter: read directly, the
                // map kept whatever value happened to be true at first composition, so granting the
                // permission afterwards never brought the blue dot back.
                isMyLocationEnabled = locationAuthorized,
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

        // Top bar: cloud (settings) · walk title (leaves for the walk's page) · house (the list)
        Row(
            Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassCircleButton(onClick = onOpenSettings, label = "Settings") {
                BrandIcon(R.drawable.icon_cloud, 20.dp)
            }
            Spacer(Modifier.weight(1f))
            Surface(
                shape = RoundedCornerShape(22.dp),
                color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
                tonalElevation = 3.dp,
                onClick = { if (exp != null) onShowWalk() else onBrowse() },
            ) {
                Row(
                    Modifier.height(44.dp).padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Tinted like iOS, where the whole button label takes the accent.
                    Text(
                        exp?.displayName ?: Brand.NAME,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 1,
                    )
                    Spacer(Modifier.width(6.dp))
                    BrandIcon(R.drawable.icon_back, 11.dp, mirrored = true)
                }
            }
            Spacer(Modifier.weight(1f))
            GlassCircleButton(onClick = onBrowse, label = "Soundwalks") {
                BrandIcon(R.drawable.icon_home, 22.dp)
            }
        }

        // Transport. Only offered once a walk is loaded: with nothing loaded there is no clip to
        // start and nowhere to skip to, and the map is just a map.
        if (exp != null) {
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    // Above the intro card *and* its scrim: the same button drives the whole walk,
                    // so it must not be dimmed by the overlay behind it, and pressing it has to
                    // start the walk rather than merely dismissing the card.
                    .zIndex(2f)
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
                        phase = downloadPhase,
                    ) {
                        if (showIntro) app.dismissIntroCard()
                        app.togglePlayback()
                    }
                    SkipButton(RenderEngine.SKIP_INTERVAL_SECONDS, isRunning) { app.engine.skip(it) }
                }
            }
        }

        // Cards sit over the map but under the transport — zIndex, not draw order, so the two
        // relationships stay explicit no matter how this Box is later rearranged.
        if (showIntro && exp != null) {
            Box(Modifier.zIndex(1f)) {
                WalkIntroCard(app = app, experience = exp, onOpenArtist = onOpenArtist)
            }
        } else if (showFarAway && exp != null) {
            Box(Modifier.zIndex(1f)) {
                FarAwayCard(
                    walkName = exp.displayName,
                    distanceMiles = app.currentWalkDistanceMiles,
                    onBrowse = { app.dismissFarAwayCard(); onBrowse() },
                    onDismiss = { app.dismissFarAwayCard() },
                )
            }
        }
    }
}

@Composable
private fun GlassCircleButton(onClick: () -> Unit, label: String, content: @Composable () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.85f),
        tonalElevation = 3.dp,
        onClick = onClick,
        modifier = Modifier.size(44.dp).semantics { contentDescription = label },
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
        modifier = Modifier.size(60.dp),
    ) {
        Box(
            Modifier.fillMaxSize().semantics {
                contentDescription = if (delta < 0) "Back 15 seconds" else "Forward 15 seconds"
            },
            contentAlignment = Alignment.Center,
        ) {
            // Dorothy's drawn arrows — a separate one each way, so nothing is mirrored here.
            BrandIcon(
                if (delta < 0) R.drawable.icon_back15 else R.drawable.icon_forward15, 34.dp,
                modifier = Modifier.graphicsLayer { alpha = if (live) 1f else 0.35f },
            )
        }
    }
}

/** The big play/pause. While a walk downloads it shows progress instead — there is nothing to play
 *  until that completes, so the tap is swallowed rather than the button dimmed. */
@Composable
private fun PlayButton(
    isRunning: Boolean,
    downloading: Boolean,
    progress: Double,
    phase: DownloadPhase,
    onClick: () -> Unit,
) {
    val fill = Color(0xFF5C6169)
    // Sized for the ring whether or not it is showing. iOS draws the ring as an overlay, which
    // takes no layout; here the ring is a sibling, and letting the box grow with it dropped the
    // whole transport 8 dp the moment a download finished.
    Box(Modifier.size(100.dp), contentAlignment = Alignment.Center) {
        if (downloading) {
            Surface(
                shape = CircleShape,
                color = fill,
                shadowElevation = 12.dp,
                onClick = {},
                modifier = Modifier.size(84.dp),
            ) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        if (phase == DownloadPhase.PREPARING) "Preparing" else "Downloading",
                        color = Color.White,
                        fontSize = 13.sp,
                        maxLines = 1,
                    )
                }
            }
        } else {
            // Dorothy's drawn buttons are the whole control — disc, colour and glyph.
            Box(
                Modifier
                    .size(84.dp)
                    .shadow(12.dp, CircleShape, clip = false, ambientColor = Color.Black.copy(alpha = 0.25f))
                    .clip(CircleShape)
                    .clickable(onClick = onClick)
                    .semantics { contentDescription = if (isRunning) "Pause" else "Play" },
                contentAlignment = Alignment.Center,
            ) {
                BrandIcon(if (isRunning) R.drawable.icon_pause else R.drawable.icon_play, 84.dp)
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
