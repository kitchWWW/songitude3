package com.brianellissound.songitude.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brianellissound.songitude.R
import com.brianellissound.songitude.ui.Brand
import com.brianellissound.songitude.ui.BrandPrimaryButton
import com.brianellissound.songitude.ui.LivingBackdrop
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.random.Random

/** The steps of the first launch. Android has one more than iOS: the notification permission,
 *  which the foreground-service transport needs on Android 13+. */
enum class FirstRunStep { LANDING, LOCATION, NOTIFICATION }

/**
 * The first launch, as one scene (Figma "App Loading", `72:154`, and the iOS `FirstRunView`):
 *
 * 1. **Landing** — CHROMIC in the display face across the middle of the wash, white squiggles,
 *    stars and dots drifting over it. Tap anywhere to go on.
 * 2. **Location** — the title lifts to the top, the app icon and the location ask fade in
 *    beneath it, the squiggles keep drifting but thin out behind the copy.
 * 3. **Notification** (Android 13+ only) — the same frame, asking for the playback notification.
 *
 * Replaces Songitude's splash animation and its logo hand-off. The permission logic itself —
 * launchers, the busy state while a system screen is up — stays in `MainActivity`, as it was.
 * The advance buttons say "Continue", never "Enable": App Review 5.1.1(iv) on iOS, and the same
 * reasoning here.
 */
@Composable
fun FirstRunScreen(
    step: FirstRunStep,
    /** True while a system permission screen is up: the button shows a spinner and holds. */
    busy: Boolean,
    onBegin: () -> Unit,
    onContinue: () -> Unit,
    onNotNow: () -> Unit,
) {
    val landing = step == FirstRunStep.LANDING
    // Title placement as a fraction of the screen height (mock: centre at 331/812 on the landing).
    val titleY by animateFloatAsState(if (landing) 0.41f else 0.14f, tween(550), label = "titleY")
    val titleScale by animateFloatAsState(if (landing) 1f else 0.7f, tween(550), label = "titleScale")
    val fade by animateFloatAsState(if (landing) 0f else 1f, tween(550), label = "fade")

    BoxWithConstraints(Modifier.fillMaxSize()) {
        val h = maxHeight
        LivingBackdrop()
        // On the permission steps the field thins out towards the bottom, so nothing drifts
        // through the copy and the buttons.
        SquiggleField(Modifier.fillMaxSize(), fadeFrom = 0.55f, fadeTo = 0.72f, fadeAmount = fade)

        if (!landing) {
            PermissionBlock(
                step = step, busy = busy,
                topInset = h * 0.14f + 60.dp,
                onContinue = onContinue, onNotNow = onNotNow,
            )
        }

        // 64sp on the landing (the mock's), scaled rather than re-set on the permission steps so
        // the move is one continuous animation instead of a font swap.
        Text(
            "chromic",
            style = Brand.titleStyle(64.sp).copy(letterSpacing = (-0.64).sp),
            maxLines = 1,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset { IntOffset(0, (h.toPx() * titleY - 48.dp.toPx()).roundToInt()) }
                .graphicsLayer { scaleX = titleScale; scaleY = titleScale }
                .padding(horizontal = 24.dp),
        )

        if (landing) {
            // The whole screen is the button. The hint sits where the mock keeps its "tag line?"
            // placeholder; swap it for the real tagline when there is one.
            Box(
                Modifier.fillMaxSize().clickable(
                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                    role = Role.Button, onClickLabel = "Begin", onClick = onBegin,
                )
            )
            Text(
                "Tap to begin",
                style = Brand.body(16, FontWeight.SemiBold).copy(color = Brand.Palette.onBackdrop.copy(alpha = 0.6f)),
                modifier = Modifier.align(Alignment.TopCenter).offset(y = h * 0.87f - 10.dp),
            )
        }
    }
}

/** The app icon and the ask at the bottom: copy, Continue, Not now, fine print. */
@Composable
private fun PermissionBlock(
    step: FirstRunStep,
    busy: Boolean,
    topInset: androidx.compose.ui.unit.Dp,
    onContinue: () -> Unit,
    onNotNow: () -> Unit,
) {
    Column(
        Modifier.fillMaxSize().navigationBarsPadding(),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(topInset))
        // The icon, as it sits on the home screen: the piano at the launcher's corner radius.
        Image(
            painterResource(R.drawable.icon_tile), contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(120.dp)
                .shadow(18.dp, RoundedCornerShape(27.dp), clip = false, ambientColor = Color.Black.copy(alpha = 0.18f))
                .clip(RoundedCornerShape(27.dp)),
        )
        Spacer(Modifier.weight(1f))
        Column(
            Modifier.padding(horizontal = Brand.PAGE_INSET).padding(bottom = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (step == FirstRunStep.LOCATION) {
                // Why we are about to ask. Describes the app's own behaviour and nothing about the
                // dialog that follows or how to answer it.
                Text(
                    "${Brand.NAME} needs your location to play the sounds placed around you and follow you as you walk.",
                    style = Brand.body(16, FontWeight.SemiBold).copy(color = Brand.Palette.bodyText),
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 4.dp),
                )
            } else {
                // Songitude's notification page, word for word. The wording is careful on purpose:
                // Android shows a persistent playback control while a walk runs — that is the
                // mechanism that keeps the audio alive with the screen off — so promising "no
                // notifications" flatly would be a promise the app visibly breaks the first time
                // you press play. What it does promise is the thing people actually mean: nothing
                // is ever pushed at you.
                Text("One more thing", style = Brand.body(22, FontWeight.Bold).copy(color = Brand.Palette.bodyText))
                Text(
                    "So the music keeps playing.",
                    style = Brand.body(16).copy(color = Brand.Palette.bodyText), textAlign = TextAlign.Center,
                )
                Column(Modifier.fillMaxWidth().padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Bullet("For the best experience, you might want to lock your phone and put it in your pocket.")
                    Bullet("In order to keep giving you location-accurate audio, we need permission to run in the background.")
                }
                Text(
                    "We will never send you a notification. Nothing is ever pushed at you — no alerts, no announcements, no reminders.",
                    style = Brand.body(14, FontWeight.SemiBold).copy(color = Brand.Palette.bodyText),
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 4.dp),
                )
            }
            Box(Modifier.padding(top = 6.dp)) {
                BrandPrimaryButton(if (busy) "" else "Continue", enabled = !busy, onClick = onContinue)
                if (busy) {
                    // Android's own permission UI can take a moment to appear, and a dead-looking
                    // button in that gap reads as a missed tap. The spinner is the acknowledgement.
                    CircularProgressIndicator(
                        Modifier.align(Alignment.Center).size(20.dp), strokeWidth = 2.dp,
                        color = Brand.Palette.startLabel,
                    )
                }
            }
            // The way in without granting anything. It also means this screen can never strand
            // anyone: if the system declines to present the dialog at all, this is still a way on.
            TextButton(onClick = onNotNow, enabled = !busy) {
                Text("Not now", style = Brand.body(15, FontWeight.Medium).copy(color = Brand.Palette.bodyText.copy(alpha = 0.75f)))
            }
            if (step == FirstRunStep.LOCATION) {
                Text(
                    "We only use your location to play the right sounds around you, never to track or share where you are.",
                    style = Brand.body(12).copy(color = Brand.Palette.bodyText.copy(alpha = 0.65f)),
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 8.dp),
                )
            }
        }
    }
}

/** One bulleted line of onboarding copy, left-aligned so the markers line up. */
@Composable
private fun Bullet(text: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Text("•", style = Brand.body(15).copy(color = Brand.Palette.bodyText))
        Spacer(Modifier.width(10.dp))
        Text(text, style = Brand.body(15).copy(color = Brand.Palette.bodyText), modifier = Modifier.weight(1f))
    }
}

// MARK: - Drifting squiggles

private class Sprite(
    val res: Int,
    val originX: Float, val originY: Float,   // unit square
    val dx: Float, val dy: Float,             // unit lengths per second
    val scale: Float,
    val spin: Float,                          // radians per second
    val swayPhase: Float, val swayPeriod: Float,
    val alpha: Float,
)

/** A fresh, random arrangement: enough pieces to read as a field, none big enough to crowd the
 *  title. Roughly the mock's mix — more dots than stars, more stars than squiggles. */
private fun scatter(): List<Sprite> {
    val kinds = listOf(
        R.drawable.squiggle1, R.drawable.squiggle2, R.drawable.squiggle3, R.drawable.squiggle2,
        R.drawable.star1, R.drawable.star2, R.drawable.star3, R.drawable.star1, R.drawable.star3,
        R.drawable.dot1, R.drawable.dot2, R.drawable.dot3, R.drawable.dot1, R.drawable.dot2,
        R.drawable.dot3, R.drawable.dot2, R.drawable.dot1, R.drawable.dot3,
    )
    val dots = setOf(R.drawable.dot1, R.drawable.dot2, R.drawable.dot3)
    val r = Random(System.nanoTime())
    return kinds.map { res ->
        // Mostly upward, a little sideways: the squiggles read as rising through the wash.
        val angle = r.nextDouble(-PI * 0.35, PI * 0.35) - PI / 2
        val speed = r.nextDouble(0.010, 0.022)     // 60–120 s to cross the screen
        Sprite(
            res = res,
            originX = r.nextFloat(), originY = r.nextFloat(),
            dx = (cos(angle) * speed).toFloat(), dy = (sin(angle) * speed).toFloat(),
            scale = if (res in dots) r.nextDouble(0.8, 1.2).toFloat() else r.nextDouble(0.8, 1.3).toFloat(),
            spin = r.nextDouble(-0.12, 0.12).toFloat(),
            swayPhase = r.nextDouble(0.0, 2 * PI).toFloat(), swayPeriod = r.nextDouble(6.0, 11.0).toFloat(),
            alpha = r.nextDouble(0.8, 1.0).toFloat(),
        )
    }
}

/**
 * The welcome-screen decorations drifting slowly across the screen, each on its own heading with
 * a gentle sway and a slow turn, wrapping round when it leaves. One Canvas, one frame clock. The
 * sprites are the iOS 3× bitmaps, so they are drawn at a third of their pixel size in dp.
 */
@Composable
private fun SquiggleField(
    modifier: Modifier = Modifier,
    /** Fade the field to nothing between these fractions of the height, by `fadeAmount`. */
    fadeFrom: Float = 1f, fadeTo: Float = 1f, fadeAmount: Float = 0f,
) {
    val sprites = remember { scatter() }
    val ctx = LocalContext.current
    val bitmaps = remember { sprites.map { it.res }.distinct().associateWith { ImageBitmap.imageResource(ctx.resources, it) } }
    var t by remember { mutableStateOf(0f) }
    LaunchedEffect(Unit) {
        val start = withInfiniteAnimationFrameNanos { it }
        while (true) withInfiniteAnimationFrameNanos { now -> t = ((now - start) / 1e9).toFloat() }
    }
    Canvas(
        modifier
            // Rendered offscreen so the gradient below can multiply into the field's own alpha
            // (DstIn) — a real mask, rather than painting something over the wash.
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                if (fadeAmount > 0f) {
                    val keep = 1f - fadeAmount
                    drawRect(
                        Brush.verticalGradient(
                            0f to Color.Black, fadeFrom to Color.Black,
                            fadeTo to Color.Black.copy(alpha = keep), 1f to Color.Black.copy(alpha = keep),
                        ),
                        blendMode = BlendMode.DstIn,
                    )
                }
            }
    ) {
            val m = 0.12f   // margin so a sprite finishes leaving before it re-enters
            val span = 1f + 2 * m
            for (s in sprites) {
                val img = bitmaps[s.res] ?: continue
                var x = (s.originX + s.dx * t + m) % span; if (x < 0) x += span; x -= m
                var y = (s.originY + s.dy * t + m) % span; if (y < 0) y += span; y -= m
                val sway = sin(t * 2 * PI / s.swayPeriod + s.swayPhase).toFloat() * 10.dp.toPx()
                val cx = x * size.width + sway; val cy = y * size.height
                val w = img.width / 3f * density * s.scale; val h = img.height / 3f * density * s.scale
                translate(cx, cy) {
                    rotate(Math.toDegrees((s.spin * t).toDouble()).toFloat(), Offset.Zero) {
                        drawImage(
                            img, dstOffset = androidx.compose.ui.unit.IntOffset((-w / 2).roundToInt(), (-h / 2).roundToInt()),
                            dstSize = androidx.compose.ui.unit.IntSize(w.roundToInt(), h.roundToInt()),
                            alpha = s.alpha,
                        )
                    }
                }
            }
    }
}
