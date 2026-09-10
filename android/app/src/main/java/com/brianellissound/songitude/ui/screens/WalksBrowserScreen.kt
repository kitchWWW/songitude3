package com.brianellissound.songitude.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.model.GeoUtils
import kotlin.math.roundToInt

/**
 * Full-screen list of published walks, nearest-first. Downloads on demand; pull to refresh; a
 * downloaded walk can be uninstalled; tapping a creator opens their artist page.
 *
 * Ported from ios/.../Views/WalksBrowserView.swift, including the two collapsible sections — the
 * "Listen From Anywhere" group is what lets a walk be heard away from where it was composed.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WalksBrowserScreen(
    app: AppState,
    onClose: () -> Unit,
    onOpenArtist: (String, String) -> Unit,
) {
    val walks by app.walks.collectAsState()
    val loading by app.catalogLoading.collectAsState()
    val error by app.catalogError.collectAsState()
    val downloaded by app.downloadedIds.collectAsState()
    val here by app.location.location.collectAsState()

    var showGeoLocked by remember { mutableStateOf(true) }
    var showAnywhere by remember { mutableStateOf(true) }

    LaunchedEffect(Unit) {
        // Order by distance every time the list opens; the fix lands asynchronously and AppState
        // re-sorts the catalog when it does.
        app.location.requestOneShotFix()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Soundwalks") },
                navigationIcon = {
                    IconButton(onClick = onClose) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back to the map")
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize()) {
            if (loading && walks.isEmpty()) {
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(24.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text("Loading walks…", color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f))
                    }
                }
            } else if (walks.isEmpty()) {
                item {
                    Column(Modifier.padding(24.dp)) {
                        // There is always something published, so an empty catalog means we couldn't
                        // reach it — not that no walks exist.
                        Text("No connection", style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            error ?: "Songitude needs the internet to find soundwalks. Pull down to try again.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        )
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = { app.refreshCatalog() }) { Text("Try again") }
                    }
                }
            } else {
                val geo = walks.filter { it.portable != true }
                val anywhere = walks.filter { it.portable == true }

                if (geo.isNotEmpty()) {
                    item { CollapsibleHeader("Geo-Locked", showGeoLocked) { showGeoLocked = !showGeoLocked } }
                    if (showGeoLocked) items(geo, key = { it.id }) { w ->
                        WalkRow(w, app, downloaded.contains(w.id), here,
                            onOpen = { app.openRemote(w); onClose() },
                            onArtist = { id -> onOpenArtist(id, w.creatorText) })
                    }
                }
                if (anywhere.isNotEmpty()) {
                    item { CollapsibleHeader("Listen From Anywhere", showAnywhere) { showAnywhere = !showAnywhere } }
                    if (showAnywhere) items(anywhere, key = { it.id }) { w ->
                        WalkRow(w, app, downloaded.contains(w.id), here,
                            onOpen = { app.openRemote(w); onClose() },
                            onArtist = { id -> onOpenArtist(id, w.creatorText) })
                    }
                }
            }
        }
    }
}

@Composable
private fun CollapsibleHeader(title: String, isOpen: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onToggle).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )
        Spacer(Modifier.weight(1f))
        Icon(
            if (isOpen) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
        )
    }
}

@Composable
private fun WalkRow(
    walk: RemoteWalk,
    app: AppState,
    isDownloaded: Boolean,
    here: com.brianellissound.songitude.model.LatLngD?,
    onOpen: () -> Unit,
    onArtist: (String) -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }

    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = walk.artUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(56.dp).clip(RoundedCornerShape(10.dp)),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(walk.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            val creator = walk.creatorText
            if (creator.isNotEmpty()) {
                val artistId = walk.artistId
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "by $creator",
                        style = MaterialTheme.typography.bodySmall,
                        color = if (artistId != null) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        modifier = if (artistId != null) Modifier.clickable { onArtist(artistId) } else Modifier,
                    )
                    if (artistId != null) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val distance = here?.let { h ->
                    walk.centerCoord?.let { c -> GeoUtils.distance(h, c) }
                }
                if (walk.portable == true) {
                    Text(
                        "Plays anywhere",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                } else if (distance != null) {
                    val miles = distance / 1609.344
                    Text(
                        if (miles < 0.19) "${(distance * 3.28084).roundToInt()} ft away"
                        else "${miles.roundToInt()} miles away",
                        style = MaterialTheme.typography.labelSmall,
                        color = if (miles < 0.19) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                }
                walk.sizeBytes?.let {
                    Text(
                        humanSize(it),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                }
                if (isDownloaded) {
                    Text(
                        "Installed",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                }
            }
        }
        if (isDownloaded) {
            IconButton(onClick = { confirmDelete = true }) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Uninstall ${walk.name}",
                    tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.5f),
                )
            }
        }
        IconButton(onClick = onOpen) {
            Icon(Icons.Filled.PlayCircleOutline, contentDescription = "Open ${walk.name}")
        }
    }
    HorizontalDivider()

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Uninstall “${walk.name}”?") },
            text = { Text("Its files are removed from this phone. The walk stays published — you can download it again any time.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; app.deleteDownloaded(walk.id) }) {
                    Text("Uninstall")
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

private fun humanSize(bytes: Long): String = when {
    bytes >= 1_000_000 -> "${(bytes / 100_000) / 10.0} MB"
    bytes >= 1_000 -> "${bytes / 1000} KB"
    else -> "$bytes B"
}
