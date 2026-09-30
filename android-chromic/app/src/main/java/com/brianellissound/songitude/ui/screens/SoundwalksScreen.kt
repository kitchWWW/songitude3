package com.brianellissound.songitude.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.R
import com.brianellissound.songitude.data.RemoteWalk
import com.brianellissound.songitude.model.GeoUtils
import com.brianellissound.songitude.model.LatLngD
import com.brianellissound.songitude.ui.*

/**
 * The list of Chromic's soundwalks as a column of cards over the wash, nearest first (Figma
 * "Home", `23:142`). Tapping a card opens its page; the artist's name goes home to About. Pull
 * down to refresh; long-press an installed card to remove its download. "Powered by Songitude"
 * at the foot links to Songitude's store page.
 *
 * Differs from Songitude's list on purpose: one flat list rather than geo-locked / anywhere
 * sections — the card says which — a custom title in the display face instead of an app bar, and
 * no download state on the card, because downloading starts from the walk's page and shows on the
 * map's play button.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun SoundwalksScreen(
    app: AppState,
    onOpen: (RemoteWalk) -> Unit,
    onArtist: () -> Unit,
    onBack: () -> Unit,
) {
    val walks by app.walks.collectAsState()
    val loading by app.catalogLoading.collectAsState()
    val error by app.catalogError.collectAsState()
    val here by app.location.location.collectAsState()
    val downloaded by app.downloadedIds.collectAsState()
    val downloadingId by app.downloadingWalkId.collectAsState()
    val contentVersion by app.contentVersion.collectAsState()
    val context = LocalContext.current
    var refreshing by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        // Order by distance every time the list opens; the fix lands asynchronously and AppState
        // re-sorts the catalog when it does.
        app.location.requestOneShotFix()
    }

    Box(Modifier.fillMaxSize()) {
        LivingBackdrop()
        // Welcome's drifting squiggles, unfaded. Siblings of the wash rather than list items, so
        // like the wash they hold still while the cards scroll over them.
        SquiggleField(Modifier.fillMaxSize())
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { refreshing = true; app.refreshCatalog { refreshing = false } },
        ) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 40.dp)) {
                item { ScreenHeader("soundwalks", onBack, back = HeaderBack.About); Spacer(Modifier.height(25.dp)) }
                when {
                    loading && walks.isEmpty() -> item {
                        Row(
                            Modifier.fillMaxWidth().padding(top = 40.dp), horizontalArrangement = Arrangement.Center,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp, color = Brand.Palette.subtitle)
                            Spacer(Modifier.width(10.dp))
                            Text("Loading walks…", style = Brand.body(15).copy(color = Brand.Palette.subtitle))
                        }
                    }
                    walks.isEmpty() -> item {
                        // There is always something published, so an empty catalog means we
                        // couldn't reach it — not that no walks exist.
                        Notice(
                            if (error != null) "Couldn't load walks" else "No connection",
                            error ?: "${Brand.NAME} needs the internet to find soundwalks. Pull down to try again.",
                        )
                    }
                    else -> items(walks, key = { it.id }) { walk ->
                        WalkCard(
                            walk = walk, here = here,
                            // Cache-then-seed: the disk (or seed) copy first, refetched behind it.
                            art = remember(walk.artUrl, contentVersion) { walk.artUrl?.let { app.content.cachedFile(it) } ?: walk.artUrl },
                            canRemove = downloaded.contains(walk.id) && downloadingId != walk.id,
                            onOpen = { onOpen(walk) }, onArtist = onArtist,
                            onRemove = { app.deleteDownloaded(walk.id) },
                        )
                        Spacer(Modifier.height(39.dp))   // 39pt between cards in the mock
                    }
                }
                item {
                    // The engine's credit, at the foot of the list.
                    Text(
                        "Powered by Songitude",
                        style = Brand.body(13, FontWeight.Medium).copy(
                            color = Brand.Palette.onBackdrop.copy(alpha = 0.7f), textDecoration = TextDecoration.Underline,
                        ),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 8.dp)
                            .combinedClickable(onClick = {
                                context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Brand.SONGITUDE_URL)))
                            })
                            .padding(8.dp)
                            .wrapContentWidth(Alignment.CenterHorizontally),
                    )
                    Spacer(Modifier.navigationBarsPadding())
                }
            }
        }
    }
}

/** One walk in the list: artwork on top, title and a one-line subtitle beneath, on a pale card
 *  (Figma "Stacked card": 360×264, r12, #FEF7FF on a #CAC4D0 hairline; media 188pt; text 16/14).
 *  The subtitle is the artist's name — a link to About — with the distance at the trailing edge. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun WalkCard(
    walk: RemoteWalk,
    here: LatLngD?,
    art: Any?,
    canRemove: Boolean,
    onOpen: () -> Unit,
    onArtist: () -> Unit,
    onRemove: () -> Unit,
) {
    var confirmRemove by remember { mutableStateOf(false) }
    val shape = RoundedCornerShape(Brand.CARD_RADIUS)
    Column(
        Modifier
            .padding(horizontal = Brand.CARD_INSET)
            .fillMaxWidth()
            .clip(shape)
            .background(Brand.Palette.card)
            .border(1.dp, Brand.Palette.cardStroke, shape)
            // The card opens the walk; a long press on an installed one offers to remove the
            // download (Songitude's swipe has no home on a card).
            .combinedClickable(onClick = onOpen, onLongClick = { if (canRemove) confirmRemove = true }),
    ) {
        ArtworkBox(Brand.CARD_MEDIA_ASPECT) {
            AsyncImage(
                model = art, contentDescription = null,
                contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
            )
        }
        Column(Modifier.padding(16.dp)) {
            Text(
                walk.name, style = Brand.body(16).copy(color = Brand.Palette.title),
                maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.height(2.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                ArtistLink(walk.creatorText, onArtist)
                Spacer(Modifier.weight(1f))
                whereabouts(walk, here)?.let {
                    Text(it, style = Brand.body(13).copy(color = Brand.Palette.subtitle), maxLines = 1)
                }
            }
        }
    }
    if (confirmRemove) {
        AlertDialog(
            onDismissRequest = { confirmRemove = false },
            title = { Text("Remove download?") },
            text = { Text("${walk.name} stays in the list; its audio is deleted from this phone.") },
            confirmButton = { TextButton(onClick = { confirmRemove = false; onRemove() }) { Text("Remove") } },
            dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text("Cancel") } },
        )
    }
}

/** The artist's name as a link to About — the same line on the card and on the walk's page. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ArtistLink(name: String, onClick: () -> Unit) {
    Row(
        Modifier.combinedClickable(onClick = onClick).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(name.ifEmpty { Brand.NAME }, style = Brand.body(14).copy(color = Brand.Palette.title), maxLines = 1)
        // The back chevron, turned round: the set has no forward one.
        BrandIcon(R.drawable.icon_back, 10.dp, mirrored = true)
    }
}

/** Where the walk is, from here; a portable walk says so instead. null without a fix. Same
 *  thresholds as Songitude's row: feet up close, tenths of a mile, then whole miles. */
private fun whereabouts(walk: RemoteWalk, here: LatLngD?): String? {
    if (walk.portable == true) return "Listen from anywhere"
    val c = walk.centerCoord ?: return null
    val m = here?.let { GeoUtils.distance(it, c) } ?: return null
    val miles = m / 1609.344
    return when {
        miles < 0.1 -> "${((m * 3.28084 / 10).let { Math.round(it) * 10 })} ft away"
        miles < 10 -> String.format("%.1f miles away", miles)
        else -> "${Math.round(miles)} miles away"
    }
}

/** Loading / error / offline copy, set on a card so it reads over the wash. */
@Composable
private fun Notice(title: String, detail: String) {
    Column(
        Modifier
            .padding(horizontal = Brand.CARD_INSET)
            .fillMaxWidth()
            .background(Brand.Palette.card, RoundedCornerShape(Brand.CARD_RADIUS))
            .padding(16.dp),
    ) {
        Text(title, style = Brand.body(16, FontWeight.SemiBold).copy(color = Brand.Palette.title))
        Spacer(Modifier.height(4.dp))
        Text(detail, style = Brand.body(14).copy(color = Brand.Palette.subtitle))
    }
}
