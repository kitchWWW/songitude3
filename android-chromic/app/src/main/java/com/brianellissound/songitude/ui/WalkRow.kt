package com.brianellissound.songitude.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.model.GeoUtils
import com.brianellissound.songitude.model.LatLngD
import kotlin.math.roundToInt

/**
 * One walk in a list. Shared by the walks browser and the artist page so both look and behave
 * identically — same status glyph, same tap-to-open, same distance wording.
 *
 * Ported from ios/.../Views/WalkRow.swift.
 */
@Composable
fun WalkRow(
    walk: RemoteWalk,
    app: AppState,
    here: LatLngD?,
    onOpen: () -> Unit,
    /** Tapping the creator opens that artist's page. Null — as on the artist's own page — leaves
     *  the name as plain text. */
    onArtist: ((String) -> Unit)? = null,
    showUninstall: Boolean = true,
) {
    val downloadingId by app.downloadingWalkId.collectAsState()
    val progress by app.downloadProgress.collectAsState()
    val downloaded by app.downloadedIds.collectAsState()
    val current by app.current.collectAsState()

    val downloading = downloadingId == walk.id
    val isCurrent = current?.id == walk.id
    val isDownloaded = downloaded.contains(walk.id)
    var confirmDelete by remember { mutableStateOf(false) }

    Row(
        Modifier
            .fillMaxWidth()
            // A downloading row ignores taps: it is already on its way in.
            .clickable(enabled = !downloading, onClick = onOpen)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = walk.artUrl,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(54.dp)
                .clip(RoundedCornerShape(9.dp))
                .border(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), RoundedCornerShape(9.dp)),
        )
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(walk.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)

            val creator = walk.creatorText
            if (creator.isNotEmpty()) {
                val artistId = walk.artistId?.takeIf { it.isNotEmpty() }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    // Only the name reads as the link — "by" stays ordinary caption text.
                    Text(
                        "by ",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                    Text(
                        creator,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (artistId != null && onArtist != null) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                        modifier = if (artistId != null && onArtist != null)
                            Modifier.clickable { onArtist(artistId) } else Modifier,
                    )
                    if (artistId != null && onArtist != null) {
                        Icon(
                            Icons.AutoMirrored.Filled.KeyboardArrowRight,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(13.dp),
                        )
                    }
                }
            }

            // Only facts that never change while downloading live here, so the row's text can't
            // reflow mid-download — state is carried entirely by the status glyph.
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val metres = here?.let { h -> walk.centerCoord?.let { GeoUtils.distance(h, it) } }
                if (metres != null) {
                    Text(
                        distanceText(metres),
                        style = MaterialTheme.typography.labelSmall,
                        color = if (metres < NEARBY_METRES) Color(0xFF2E7D32)
                        else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                }
                walk.sizeBytes?.let {
                    Text(
                        sizeText(it),
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
        Spacer(Modifier.width(8.dp))

        if (showUninstall && isDownloaded && !downloading) {
            IconButton(onClick = { confirmDelete = true }, modifier = Modifier.size(36.dp)) {
                Icon(
                    Icons.Filled.Delete,
                    contentDescription = "Uninstall ${walk.name}",
                    tint = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.45f),
                    modifier = Modifier.size(20.dp),
                )
            }
        }

        // A fixed box, so a download starting never resizes anything around it.
        Box(Modifier.size(30.dp), contentAlignment = Alignment.Center) {
            when {
                downloading -> CircularProgressIndicator(
                    // Always show a sliver, even at 0%.
                    progress = { progress.toFloat().coerceIn(0.03f, 1f) },
                    modifier = Modifier.size(22.dp),
                    strokeWidth = 3.dp,
                )
                isCurrent -> Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = "Loaded",
                    tint = Color(0xFF2E7D32),
                )
                // Always "play": downloading is an implementation detail the listener shouldn't have
                // to think about — tapping either plays straight away, or fetches and then plays.
                else -> Icon(
                    Icons.Filled.PlayCircleOutline,
                    contentDescription = "Open ${walk.name}",
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
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

/** Walks within this range read as "close enough to go and hear right now". */
private const val NEARBY_METRES = 2 * 1609.344

/** Feet up close, miles beyond a tenth of a mile, whole miles once precision stops mattering. */
private fun distanceText(m: Double): String {
    val miles = m / 1609.344
    if (miles < 0.1) {
        val feet = ((m * 3.28084 / 10).roundToInt() * 10)   // nearest 10 ft
        return "$feet ft away"
    }
    if (miles < 10) return String.format("%.1f miles away", miles)
    return "${miles.roundToInt()} miles away"
}

private fun sizeText(b: Long): String =
    if (b >= 1_000_000) String.format("%.1f MB", b / 1e6) else "${b / 1000} KB"
