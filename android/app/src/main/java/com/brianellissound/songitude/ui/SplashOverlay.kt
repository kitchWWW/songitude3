package com.brianellissound.songitude.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.ui.draw.drawBehind
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Where the launch animation has got to. */
enum class SplashPhase { WAVES, FLYING, DONE }

/** The mark's own size on the splash — matched to what the system splash draws, so the animation
 *  opens on exactly the picture the system handed over. The onboarding slot is 100dp, so it shrinks
 *  as it flies. */
private const val SPLASH_TILE_DP = 168f

/** Everything after the opening hold runs this many times faster than its written timings. */
private const val PACE = 1.5
private fun beat(seconds: Double) = (seconds / PACE * 1000).toLong()

/**
 * The launch animation, drawn over the real UI and then handed off to the onboarding screen: the
 * waves pulse outward, then the tile flies up and shrinks into the exact spot where the onboarding
 * logo lives.
 *
 * Ported from ios/.../Views/SplashRootView.swift, including the details that make the hand-off read
 * as one continuous object: the tile's own background starts invisible so the mark floats on the
 * splash backdrop with no icon edges, the flight is fully damped so it never overshoots and bounces,
 * and it waits for the onboarding logo to report its position rather than flying to screen centre
 * and snapping.
 */
@Composable
fun SplashOverlay(
    phase: SplashPhase,
    logoTarget: Rect?,
    onPhase: (SplashPhase) -> Unit,
    resetToken: Int,
) {
    if (phase == SplashPhase.DONE) return

    val density = LocalDensity.current
    val tilePx = with(density) { SPLASH_TILE_DP.dp.toPx() }

    // Which wave the pulse is passing through; -1 is at rest.
    var pulse by remember(resetToken) { mutableIntStateOf(-1) }

    // Each wave eases to its new opacity rather than snapping. iOS wraps the pulse in
    // `withAnimation(.easeInOut(duration: 0.6 / pace))`, and without the equivalent the three waves
    // just blink between values — which is what made the sequence read as steps rather than as a
    // pulse travelling outward.
    val waveDuration = beat(0.6).toInt()
    val w0 by animateFloatAsState(waveOpacity(0, pulse), tween(waveDuration, easing = FastOutSlowInEasing), label = "w0")
    val w1 by animateFloatAsState(waveOpacity(1, pulse), tween(waveDuration, easing = FastOutSlowInEasing), label = "w1")
    val w2 by animateFloatAsState(waveOpacity(2, pulse), tween(waveDuration, easing = FastOutSlowInEasing), label = "w2")
    val scale = remember(resetToken) { Animatable(1f) }
    val dx = remember(resetToken) { Animatable(0f) }
    val dy = remember(resetToken) { Animatable(0f) }
    val backdrop = remember(resetToken) { Animatable(1f) }
    // The system splash can only be given a flat colour on Android 12+, so it hands over on solid
    // black. The wash blooms out of that rather than replacing it in one frame, which is what makes
    // the seam between the two invisible.
    val wash = remember(resetToken) { Animatable(0f) }
    // The mark is white against the splash's dark wash and has to become the theme's own colour by
    // the time it lands on the onboarding screen, which may well be white itself.
    val landed = MaterialTheme.colorScheme.onBackground
    // Qualified: the colour overload lives in androidx.compose.animation, while the Float one
    // imported above is from animation.core.
    val markColor = remember(resetToken) { androidx.compose.animation.Animatable(Color.White) }

    val latestTarget by rememberUpdatedState(logoTarget)
    val scope = rememberCoroutineScope()

    var rootSize by remember { mutableStateOf(Offset.Zero) }

    LaunchedEffect(resetToken) {
        wash.animateTo(1f, tween(beat(0.9).toInt(), easing = FastOutSlowInEasing))
    }

    LaunchedEffect(resetToken) {
        delay(1000)                       // hold on the logo before it stirs

        // The outward pulse: three beats plus a beat to settle.
        for (step in 0 until 3) {
            pulse = step
            delay(beat(0.7))
        }
        pulse = -1
        delay(beat(0.9))

        // The onboarding logo publishes its bounds as soon as it lays out; don't fly until it has,
        // or the tile animates to screen centre and then snaps into place.
        var waited = 0
        while (latestTarget == null && waited < 20) { delay(50); waited++ }

        val target = latestTarget
        if (target != null && rootSize != Offset.Zero) {
            onPhase(SplashPhase.FLYING)
            val fromCx = rootSize.x / 2f
            val fromCy = rootSize.y / 2f
            // Fully damped: overshooting the landing spot reads as a bounce, not a hand-off.
            val fly = spring<Float>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 220f)
            scope.launch { backdrop.animateTo(0f, tween(beat(0.5).toInt())) }
            scope.launch { markColor.animateTo(landed, tween(beat(0.5).toInt())) }
            scope.launch { scale.animateTo(target.width / tilePx, fly) }
            scope.launch { dx.animateTo(target.center.x - fromCx, fly) }
            scope.launch { dy.animateTo(target.center.y - fromCy, fly) }
            delay(beat(0.95))
        }
        onPhase(SplashPhase.DONE)
    }

    Box(
        Modifier
            .fillMaxSize()
            .then(Modifier.layoutSizeReporter { rootSize = it }),
    ) {
        // Darkest where the mark sits, lifting toward the edges — the mark pops against the centre
        // and the tile's own edges stay invisible until it flies away.
        Box(
            Modifier
                .fillMaxSize()
                .alpha(backdrop.value)
                .drawBehind {
                    // Compose's radialGradient defaults to half the *minimum* dimension, which on a
                    // tall phone barely leaves the middle of the screen — it read as a small dark
                    // blob rather than a wash. iOS uses max(w, h) * 0.62, so the darkness reaches
                    // for the corners; match that.
                    val t = wash.value
                    drawRect(
                        Brush.radialGradient(
                            colors = listOf(
                                Color.Black,
                                lerp(Color.Black, Color(0xFF121317), t),
                                lerp(Color.Black, Color(0xFF4D525C), t),
                            ),
                            center = center,
                            radius = maxOf(size.width, size.height) * 0.62f,
                        )
                    )
                }
        )
        Box(
            Modifier
                .align(androidx.compose.ui.Alignment.Center)
                .graphicsLayer {
                    scaleX = scale.value
                    scaleY = scale.value
                    translationX = dx.value
                    translationY = dy.value
                },
        ) {
            SongitudeMark(
                Modifier.size(SPLASH_TILE_DP.dp),
                waveOpacity = { i -> when (i) { 0 -> w0; 1 -> w1; else -> w2 } },
                stroke = markColor.value,
            )
        }
    }
}

/** The pulse dims one wave at a time from the inside out, with a soft trail behind it. */
private fun waveOpacity(i: Int, pulse: Int): Float = when {
    pulse < 0 -> 1f
    i == pulse -> 0.45f
    i == pulse - 1 -> 0.75f
    else -> 1f
}

/** Reports the composable's size in pixels, so the flight can be expressed as a delta from centre. */
private fun Modifier.layoutSizeReporter(onSize: (Offset) -> Unit): Modifier =
    this.onGloballyPositioned { coords ->
        onSize(Offset(coords.size.width.toFloat(), coords.size.height.toFloat()))
    }
