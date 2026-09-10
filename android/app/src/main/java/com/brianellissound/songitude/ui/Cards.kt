package com.brianellissound.songitude.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.parseHexColor
import kotlin.math.roundToInt

/** `introColor` may name the artist instead of a colour, so a palette change reaches every walk. */
private const val FOLLOW_ARTIST = "artist"

/**
 * The "about this walk" card that greets a listener when they open a walk: title, artist (linked to
 * their page) and the walk's description, over the walk's own backdrop colour.
 *
 * Dismissed by the ✕, by tapping outside it, or by the map's own play button — which stays visible
 * and interactive above this card, so one button controls the whole walk.
 *
 * Ported from ios/.../Views/WalkIntroCard.swift.
 */
@Composable
fun WalkIntroCard(app: AppState, experience: Experience, onOpenArtist: (String, String) -> Unit) {
    val showings by app.introShowings.collectAsState()
    val profiles by app.artists.collectAsState()
    val remote = app.currentRemoteWalk

    val creator = remote?.creatorText?.takeIf { it.isNotEmpty() }
        ?: experience.map.creator?.takeIf { it.isNotEmpty() }

    // The catalog's copy wins, so an edited description reaches a listener without the bundle being
    // republished; the bundle's own text is the fallback.
    val about = remote?.about?.takeIf { it.isNotEmpty() } ?: experience.map.about.orEmpty()

    // Following the artist needs their profile, which lives outside the bundle.
    val raw = experience.map.introColor
    LaunchedEffect(raw, remote?.artistId) {
        if (raw == FOLLOW_ARTIST) remote?.artistId?.let { app.loadArtist(it) }
    }
    val backdrop: Color? = when {
        raw == null -> null
        raw == FOLLOW_ARTIST -> remote?.artistId?.let { id ->
            profiles[id]?.bgColor?.let { Color(parseHexColor(it)) }
        }
        else -> Color(parseHexColor(raw))
    }
    // With an authored backdrop, flip the card's colours to suit it — a dark backdrop needs light
    // type, or the walk's own palette makes its description unreadable.
    val onBackdrop = backdrop?.let { if (it.luminance() < 0.5f) Color(0xFFF2F2F4) else Color(0xFF111111) }
        ?: MaterialTheme.colorScheme.onSurface
    val muted = onBackdrop.copy(alpha = 0.72f)

    CardScaffold(onDismiss = { app.dismissIntroCard() }) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = backdrop ?: MaterialTheme.colorScheme.surface,
            shadowElevation = 30.dp,
            modifier = Modifier.widthIn(max = 420.dp).border(
                1.dp, onBackdrop.copy(alpha = 0.08f), RoundedCornerShape(20.dp),
            ),
        ) {
            Column(Modifier.padding(20.dp)) {
                Row(verticalAlignment = Alignment.Top) {
                    Text(
                        experience.displayName,
                        style = MaterialTheme.typography.headlineSmall,
                        fontWeight = FontWeight.Bold,
                        color = onBackdrop,
                        modifier = Modifier.weight(1f),
                    )
                    Spacer(Modifier.width(12.dp))
                    IconButton(onClick = { app.dismissIntroCard() }) {
                        Icon(Icons.Filled.Close, contentDescription = "Close", tint = onBackdrop)
                    }
                }
                Spacer(Modifier.height(10.dp))

                Column(
                    Modifier.heightIn(max = 340.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    if (creator != null) {
                        val artistId = remote?.artistId?.takeIf { it.isNotEmpty() }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("by ", style = MaterialTheme.typography.bodyMedium, color = muted)
                            Text(
                                creator,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                color = if (artistId != null) MaterialTheme.colorScheme.primary else muted,
                                modifier = if (artistId != null)
                                    Modifier.clickable { onOpenArtist(artistId, creator) } else Modifier,
                            )
                            if (artistId != null) {
                                Icon(
                                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(16.dp),
                                )
                            }
                        }
                    }
                    if (about.isNotEmpty()) {
                        // Same markdown treatment as an artist bio: headings, lists, quotes, links.
                        MarkdownBody(about, color = muted)
                    }
                    // Only transportable walks can be re-placed, and only once the listener has seen
                    // the card before — the first read should just be the walk's own words.
                    if (experience.map.startAnchor != null && showings > 1) {
                        OutlinedButton(
                            onClick = { app.recenterPortableWalk() },
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(Icons.Filled.LocationOn, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Recenter here")
                        }
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
    CardScaffold(onDismiss = onDismiss) {
        Surface(
            shape = RoundedCornerShape(20.dp),
            color = MaterialTheme.colorScheme.surface,
            shadowElevation = 30.dp,
            modifier = Modifier.widthIn(max = 420.dp),
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

/**
 * The layer a card sits on.
 *
 * Deliberately draws nothing: iOS keeps the map at full brightness behind the card, and this exists
 * only to catch taps outside it. The bottom padding leaves the map's play button uncovered, so the
 * one button that drives the walk is reachable while the card is up.
 */
@Composable
private fun CardScaffold(onDismiss: () -> Unit, content: @Composable () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onDismiss,
            )
            .statusBarsPadding()
            .padding(horizontal = 24.dp)
            .padding(top = 62.dp, bottom = 150.dp),
        contentAlignment = Alignment.Center,
    ) {
        // Taps on the card itself must not fall through to the dismiss layer behind it.
        Box(
            Modifier.clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = {},
            )
        ) { content() }
    }
}
