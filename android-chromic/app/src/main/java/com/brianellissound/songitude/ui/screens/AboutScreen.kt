package com.brianellissound.songitude.ui.screens

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Language
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.R
import com.brianellissound.songitude.ui.*

/**
 * About Chromic (Figma "About", `24:2062`, titled with the name): their photo edge to edge, the
 * "Soundwalks" button under it, the bio from their published profile, and link icons. The root of
 * the stack, beneath Soundwalks (where the app lands): Soundwalks' cloud and the artist's name on
 * every walk lead back here, and "Soundwalks" is the way back to the list.
 *
 * The bio is the live profile (`artists/<id>.json`, edited from the Songitude editor) so a rewrite
 * reaches the app without a release. The photo ships in the app: the profile format has no image.
 */
@Composable
fun AboutScreen(app: AppState, onSoundwalks: () -> Unit, onBack: (() -> Unit)? = null) {
    val profiles by app.artists.collectAsState()
    val profile = profiles[Brand.ARTIST_ID]
    val context = LocalContext.current
    LaunchedEffect(Unit) { app.loadArtist(Brand.ARTIST_ID) }

    Box(Modifier.fillMaxSize()) {
        Backdrop()
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
            ScreenHeader("chromic", onBack)
            ArtworkBox(Brand.PAGE_MEDIA_ASPECT, Modifier.padding(top = 41.dp).mediaHairlines()) {
                Image(
                    painterResource(R.drawable.artist_photo), contentDescription = null,
                    contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
                )
            }
            BrandPrimaryButton(
                "Soundwalks", onClick = onSoundwalks,
                modifier = Modifier.padding(horizontal = Brand.PAGE_INSET).padding(top = 24.dp),
            )
            Box(Modifier.padding(horizontal = Brand.PAGE_INSET).padding(top = 24.dp)) {
                val bio = profile?.bio?.trim()
                when {
                    !bio.isNullOrEmpty() -> MarkdownBody(bio, color = Brand.Palette.bodyText, style = Brand.body(16))
                    profile != null -> Text("${Brand.NAME} hasn't written a bio yet.",
                        style = Brand.body(16).copy(color = Brand.Palette.subtitle))
                    else -> CircularProgressIndicator(Modifier.align(Alignment.Center).size(22.dp), strokeWidth = 2.dp,
                        color = Brand.Palette.subtitle)
                }
            }
            // Instagram, then the website — stacked, as the mock has them. Each shows only once its
            // URL is known.
            Column(
                Modifier.padding(horizontal = Brand.PAGE_INSET - 4.dp).padding(top = 40.dp, bottom = 48.dp),
                verticalArrangement = Arrangement.spacedBy(15.dp),
            ) {
                Brand.INSTAGRAM_URL?.let { url ->
                    InstagramGlyph(Modifier.size(24.dp).clickable {
                        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                    })
                }
                Brand.WEBSITE_URL?.let { url ->
                    Icon(
                        Icons.Filled.Language, contentDescription = "${Brand.NAME}'s website",
                        tint = Brand.Palette.onBackdrop,
                        modifier = Modifier.size(24.dp).clickable {
                            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                        },
                    )
                }
            }
            Spacer(Modifier.navigationBarsPadding())
        }
    }
}

/** The Instagram mark as line art: a rounded square, the lens, and the flash dot. */
@Composable
private fun InstagramGlyph(modifier: Modifier) {
    Canvas(modifier) {
        val s = size.minDimension; val w = s * 0.085f
        drawRoundRect(
            Brand.Palette.onBackdrop, topLeft = Offset(w / 2, w / 2),
            size = androidx.compose.ui.geometry.Size(s - w, s - w),
            cornerRadius = CornerRadius(s * 0.28f), style = Stroke(w),
        )
        drawCircle(Brand.Palette.onBackdrop, radius = s * 0.23f - w / 2, style = Stroke(w))
        drawCircle(Brand.Palette.onBackdrop, radius = w * 0.7f, center = Offset(s * 0.74f, s * 0.26f))
    }
}
