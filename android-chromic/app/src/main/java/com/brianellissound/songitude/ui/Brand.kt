package com.brianellissound.songitude.ui

import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brianellissound.songitude.R
import kotlin.math.PI
import kotlin.math.sin

/**
 * Everything that makes this build Chromic's app rather than Songitude — the Android twin of
 * `ios-chromic/.../Brand.swift`, value for value.
 *
 * This app is a fork of `android/` (see `../SYNC.md`): same engine, same flows, same bundle
 * format. Everything brand-specific is gathered here so a diff against `android/` shows engine
 * and flow work, not a scattering of renamed strings. Values come from the "CD App design" Figma.
 */
object Brand {
    /** The name the listener sees: onboarding, the notification, error copy. */
    const val NAME = "Chromic"

    /** The one artist whose walks this app lists; everything else in the shared catalog is
     *  filtered out in `AppState.refreshCatalog`. */
    const val ARTIST_ID = "80cda9dee7513416"

    /** Songitude greets a freshly opened walk with an "about" card over the map. Here that lives
     *  on the walk's own page and Start goes straight to the map, so the card never shows. */
    const val SHOWS_INTRO_CARD = false

    /** Songitude on the App Store — the "Powered by Songitude" credit under the list links here.
     *  (No Play listing for Songitude is public yet; the App Store page is the canonical one.) */
    const val SONGITUDE_URL = "https://apps.apple.com/app/id6787213575"

    /** About's link icons. Neither is known yet, so both icons stay hidden until filled in. */
    val INSTAGRAM_URL: String? = null
    val WEBSITE_URL: String? = null

    // MARK: Type

    /** Julius Sans One (OFL, `res/font`): the design's display face. Capitals only, so
     *  "soundwalks" sets as SOUNDWALKS whatever the string's case. */
    val display = FontFamily(Font(R.font.julius_sans_one, FontWeight.Normal))

    /** Screen titles: 40sp Julius, −0.4 tracking, centred; 64sp on the landing. */
    val TITLE_SIZE = 40.sp
    val TITLE_TRACKING = (-0.4).sp
    fun titleStyle(size: androidx.compose.ui.unit.TextUnit = TITLE_SIZE) = TextStyle(
        fontFamily = display, fontSize = size, letterSpacing = TITLE_TRACKING,
        lineHeight = size, color = Palette.onBackdrop,
    )

    /** Body copy is Roboto/Inter in the mock; the system font is that on Android. */
    fun body(size: Int, weight: FontWeight = FontWeight.Normal) =
        TextStyle(fontSize = size.sp, fontWeight = weight, lineHeight = (size * 1.375).sp)

    // MARK: Colour — the mock's card colours plus the Start button's amber.
    object Palette {
        val card = Color(0xFFFEF7FF)
        val cardStroke = Color(0xFFCAC4D0)
        val mediaFill = Color(0xFFECE6F0)
        val title = Color(0xFF1D1B20)
        val subtitle = Color(0xFF49454F)
        val bodyText = Color(0xFF1E1E1E)
        val start = Color(0xFFE5A000)
        val startLabel = Color(0xFF2C2C2C)
        /** Screen titles and the back chevron sit directly on the watercolor. */
        val onBackdrop = Color.Black
    }

    // MARK: Metrics — from the 375pt Figma frames.
    val CARD_INSET = 8.dp
    val CARD_RADIUS = 12.dp
    const val CARD_MEDIA_ASPECT = 360f / 188f
    val PAGE_INSET = 50.dp
    const val PAGE_MEDIA_ASPECT = 376f / 261f
}

/** The still watercolor wash (Drive "Background/Combined Background.png"), scaled to fill. Behind
 *  the screens that are mostly reading: the walk page and About. */
@Composable
fun Backdrop(modifier: Modifier = Modifier) {
    Image(
        painterResource(R.drawable.backdrop), contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = modifier.fillMaxSize(),
    )
}

/**
 * The wash, alive: Dorothy's five paint layers (`TrBk - Layer 1–5` → `wash1–5`), each zoomed a
 * little and swaying on its own slow x and y periods, over the still wash so a band drifting aside
 * can never open a gap. Behind the landing, the permission steps and the list.
 *
 * Travel is ±5% of the screen; the 1.12× zoom leaves 6% each side, so at the peak of any layer's
 * swing there is still no edge on screen. Periods were written as 3–10 s and slowed to a fifth
 * (`PACE`) — 15–50 s a swing — the same numbers as iOS. One frame clock drives all five layers.
 */
@Composable
fun LivingBackdrop(modifier: Modifier = Modifier) {
    var t by remember { mutableStateOf(0.0) }
    LaunchedEffect(Unit) {
        val start = withInfiniteAnimationFrameNanos { it }
        while (true) withInfiniteAnimationFrameNanos { now -> t = (now - start) / 1e9 * LIVING_PACE }
    }
    Box(modifier.fillMaxSize().clipToBounds()) {
        Image(
            painterResource(R.drawable.backdrop), contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize().scale(LIVING_ZOOM),
        )
        for (layer in LIVING_LAYERS) {
            val dx = sin(t * 2 * PI / layer.xPeriod + layer.phase).toFloat() * LIVING_TRAVEL
            val dy = sin(t * 2 * PI / layer.yPeriod + layer.phase * 0.7).toFloat() * LIVING_TRAVEL
            Image(
                painterResource(layer.res), contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = LIVING_ZOOM; scaleY = LIVING_ZOOM
                        translationX = dx * size.width; translationY = dy * size.height
                    },
            )
        }
    }
}

private class WashLayer(val res: Int, val xPeriod: Double, val yPeriod: Double, val phase: Double)
private val LIVING_LAYERS = listOf(
    WashLayer(R.drawable.wash1, 9.7, 6.1, 0.0),
    WashLayer(R.drawable.wash2, 4.3, 8.9, 1.3),
    WashLayer(R.drawable.wash3, 7.4, 3.7, 2.6),
    WashLayer(R.drawable.wash4, 3.1, 9.9, 3.9),
    WashLayer(R.drawable.wash5, 6.6, 5.2, 5.2),
)
private const val LIVING_ZOOM = 1.12f
private const val LIVING_TRAVEL = 0.05f
private const val LIVING_PACE = 0.2

/** One of Dorothy's hand-drawn icons (`icon_*`), sized by height so its own proportions hold. */
@Composable
fun BrandIcon(res: Int, height: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier, mirrored: Boolean = false) {
    Image(
        painterResource(res), contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = modifier.height(height).graphicsLayer { if (mirrored) scaleX = -1f },
    )
}

/** The mock's one button: 50dp, r8, amber, dark semibold label. Start, Soundwalks, Continue. */
@Composable
fun BrandPrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    Button(
        onClick = onClick, enabled = enabled,
        shape = RoundedCornerShape(8.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = Brand.Palette.start, contentColor = Brand.Palette.startLabel,
            disabledContainerColor = Brand.Palette.start.copy(alpha = 0.6f),
            disabledContentColor = Brand.Palette.startLabel,
        ),
        modifier = modifier.fillMaxWidth().height(50.dp),
    ) {
        Text(text, style = Brand.body(16, FontWeight.SemiBold))
    }
}

/** Screen title in the display face with an optional back chevron over its left edge — the header
 *  every catalog screen shares (Figma: title 40pt centred at y≈88; chevron 46×43 at x=16). */
@Composable
fun ScreenHeader(title: String, onBack: (() -> Unit)? = null) {
    Box(
        Modifier.fillMaxWidth().statusBarsPadding().padding(top = 36.dp).heightIn(min = 60.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title, style = Brand.titleStyle(), textAlign = TextAlign.Center,
            maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 62.dp),
        )
        if (onBack != null) {
            Box(
                Modifier
                    .align(Alignment.CenterStart)
                    .padding(start = 16.dp)
                    .size(46.dp, 43.dp)
                    .clickable(onClick = onBack)
                    .semantics { contentDescription = "Back" },
                contentAlignment = Alignment.Center,
            ) { BrandIcon(R.drawable.icon_back, 24.dp) }
        }
    }
}

/** A box of fixed aspect ratio, full width, on the card's media fill, clipping whatever fills it. */
@Composable
fun ArtworkBox(aspect: Float, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    Box(
        modifier.fillMaxWidth().aspectRatio(aspect).background(Brand.Palette.mediaFill).clipToBounds(),
        content = content,
    )
}

/** Hairlines above and below a full-bleed image, as the mock draws its media frame. */
fun Modifier.mediaHairlines(): Modifier = this.border(1.dp, Brand.Palette.cardStroke)
