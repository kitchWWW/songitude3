package com.brianellissound.songitude.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.parseHexColor
import kotlin.math.roundToInt

/**
 * The card a walk opens with: its title, artist and the composer's own note.
 * Ported from ios/.../Views/WalkIntroCard.swift.
 */
@Composable
fun WalkIntroCard(app: AppState, experience: Experience, onOpenArtist: (String, String) -> Unit) {
    val showings by app.introShowings.collectAsState()
    val remote = app.currentRemoteWalk
    val artistName = remote?.creatorText?.takeIf { it.isNotEmpty() }
        ?: experience.map.creator?.takeIf { it.isNotEmpty() }
    val backdrop = experience.map.introColor?.let { c ->
        if (c.equals("artist", true)) null else Color(parseHexColor(c))
    }

    Scrim(onDismiss = { app.dismissIntroCard() }) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = backdrop ?: MaterialTheme.colorScheme.surface,
            modifier = Modifier.fillMaxWidth().padding(24.dp),
        ) {
            Column(Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            experience.displayName,
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        if (artistName != null) {
                            val artistId = remote?.artistId
                            Text(
                                "by $artistName",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = if (artistId != null)
                                    Modifier.clickable { onOpenArtist(artistId, artistName) }
                                else Modifier,
                            )
                        }
                    }
                    IconButton(onClick = { app.dismissIntroCard() }) {
                        Icon(Icons.Filled.Close, contentDescription = "Close")
                    }
                }
                val about = experience.map.about
                if (!about.isNullOrEmpty()) {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        about,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState()),
                    )
                }
                // The recenter control only appears from the second viewing, so a first read is
                // just the walk's own words.
                if (app.currentIsPortable && showings >= 1) {
                    Spacer(Modifier.height(16.dp))
                    OutlinedButton(onClick = { app.recenterPortableWalk() }) {
                        Text("Move this walk to where I'm standing")
                    }
                }
            }
        }
    }
}

/**
 * "You look pretty far away." Advisory only — it never blocks opening the walk, and a transportable
 * walk never gets here because it re-anchors onto wherever the listener stands.
 */
@Composable
fun FarAwayCard(
    walkName: String,
    distanceMiles: Double?,
    onBrowse: () -> Unit,
    onDismiss: () -> Unit,
) {
    Scrim(onDismiss = onDismiss) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surface,
            modifier = Modifier.fillMaxWidth().padding(24.dp),
        ) {
            Column(Modifier.padding(20.dp)) {
                Text("You look pretty far away", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(8.dp))
                val far = distanceMiles?.roundToInt()
                Text(
                    if (far != null)
                        "“$walkName” is about $far miles from here. It is composed onto real streets, so you'll need to be there to hear it."
                    else
                        "“$walkName” is composed onto real streets somewhere else, so you'll need to be there to hear it.",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Or open one marked Listen From Anywhere — those move themselves to wherever you are standing.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = onBrowse) { Text("Browse walks") }
                    TextButton(onClick = onDismiss) { Text("Stay here") }
                }
            }
        }
    }
}

/** A dimmed backdrop that dismisses on tap, with the card centred over it. */
@Composable
private fun Scrim(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.45f))
            .clickable(onClick = onDismiss),
        contentAlignment = Alignment.Center,
    ) {
        // Taps on the card itself must not fall through to the scrim behind it.
        Box(Modifier.clickable(enabled = false) {}) { content() }
    }
}
