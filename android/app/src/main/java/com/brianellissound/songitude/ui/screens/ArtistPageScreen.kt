package com.brianellissound.songitude.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.model.parseHexColor
import com.brianellissound.songitude.ui.MarkdownBody
import com.brianellissound.songitude.ui.WalkRow

/** An artist's public page: their bio, then everything they have published, in the same two
 *  sections the browser uses. Ported from ios/.../Views/ArtistPageView.swift. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ArtistPageScreen(
    app: AppState,
    artistId: String,
    fallbackName: String,
    onBack: () -> Unit,
    onOpenWalk: (com.brianellissound.songitude.data.RemoteWalk) -> Unit,
) {
    val profiles by app.artists.collectAsState()
    val walks by app.walks.collectAsState()
    val here by app.location.location.collectAsState()
    LaunchedEffect(artistId) { app.loadArtist(artistId) }

    val profile = profiles[artistId]
    val mine = walks.filter { it.artistId == artistId }
    val bg = profile?.bgColor?.let { Color(parseHexColor(it)) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Artist") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
        containerColor = bg ?: MaterialTheme.colorScheme.background,
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize()) {
            item {
                Column(Modifier.padding(20.dp)) {
                    Text(
                        profile?.displayName ?: fallbackName.ifEmpty { "Artist" },
                        style = MaterialTheme.typography.headlineMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    val bio = profile?.bio
                    if (!bio.isNullOrEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        // The bio is Markdown source. Rendering it as plain text keeps every word
                        // intact; a full renderer can come later without changing the format.
                        MarkdownBody(bio, color = MaterialTheme.colorScheme.onSurface)
                    } else if (profile == null) {
                        Spacer(Modifier.height(12.dp))
                        Text("Loading…", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f))
                    }
                }
            }
            if (mine.isNotEmpty()) {
                item {
                    Text(
                        "Walks by ${profile?.displayName ?: fallbackName}",
                        Modifier.padding(start = 20.dp, top = 8.dp, bottom = 8.dp),
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
                val geo = mine.filter { it.portable != true }
                val anywhere = mine.filter { it.portable == true }
                if (geo.isNotEmpty()) {
                    item { GroupLabel("Geo-Locked") }
                    items(geo, key = { it.id }) { w ->
                        // The artist's own page leaves the creator as plain text: linking it here
                        // would just point back at the page you are already on.
                        WalkRow(w, app, here, onOpen = { onOpenWalk(w) }, onArtist = null)
                    }
                }
                if (anywhere.isNotEmpty()) {
                    item { GroupLabel("Listen From Anywhere") }
                    items(anywhere, key = { it.id }) { w ->
                        WalkRow(w, app, here, onOpen = { onOpenWalk(w) }, onArtist = null)
                    }
                }
            }
            item { Spacer(Modifier.height(32.dp)) }
        }
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(
        text,
        Modifier.padding(start = 20.dp, top = 12.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
    )
}
