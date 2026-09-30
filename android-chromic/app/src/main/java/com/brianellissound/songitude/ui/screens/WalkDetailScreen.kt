package com.brianellissound.songitude.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.ui.*

/**
 * A walk's own page (Figma "Project Page", `1:1352`): its title in the display face, the artwork
 * edge to edge, one amber Start button straight under it, the artist, and the description. Opening
 * the page starts the walk's download; Start loads the walk and presents the map — this page is where Songitude's intro card used to do its
 * reading, so the card itself is switched off (`Brand.SHOWS_INTRO_CARD`).
 */
@Composable
fun WalkDetailScreen(
    app: AppState,
    walk: RemoteWalk,
    onStart: () -> Unit,
    onArtist: () -> Unit,
    onBack: () -> Unit,
) {
    val current by app.current.collectAsState()
    val contentVersion by app.contentVersion.collectAsState()
    val art = remember(walk.artUrl, contentVersion) { walk.artUrl?.let { app.content.cachedFile(it) } ?: walk.artUrl }
    // Start downloading while they read, so Start has little or nothing left to wait for. Start
    // joins this download (see AppState.prefetch); a loaded or cached walk costs nothing.
    LaunchedEffect(walk.id) { app.prefetch(walk) }
    // The catalog's copy first — it reflects an edit without republishing the bundle — then the
    // bundle's own `about`, for a walk that predates the catalog carrying one.
    val about = walk.about?.takeIf { it.isNotBlank() }
        ?: current?.takeIf { it.id == walk.id }?.map?.about.orEmpty()

    Box(Modifier.fillMaxSize()) {
        Backdrop()
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            ScreenHeader(walk.name, onBack)
            ArtworkBox(Brand.PAGE_MEDIA_ASPECT, Modifier.padding(top = 41.dp).mediaHairlines()) {
                AsyncImage(
                    model = art, contentDescription = null,
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
                )
            }
            // Always "Start". For a walk that is already loaded it doesn't reload (that would stop
            // playback) — HomeRoot just returns to its map, where the walk is as they left it.
            BrandPrimaryButton(
                "Start", onClick = onStart,
                modifier = Modifier.padding(horizontal = Brand.PAGE_INSET).padding(top = 24.dp),
            )
            Row(
                Modifier.padding(horizontal = Brand.PAGE_INSET).padding(top = 22.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("by ", style = Brand.body(14).copy(color = Brand.Palette.subtitle))
                ArtistLink(walk.creatorText, onArtist)
            }
            if (about.isNotEmpty()) {
                MarkdownBody(
                    about, color = Brand.Palette.bodyText, style = Brand.body(16),
                    modifier = Modifier.padding(horizontal = Brand.PAGE_INSET).padding(top = 14.dp),
                )
            }
            Spacer(Modifier.height(48.dp))
            Spacer(Modifier.navigationBarsPadding())
        }
    }
}
