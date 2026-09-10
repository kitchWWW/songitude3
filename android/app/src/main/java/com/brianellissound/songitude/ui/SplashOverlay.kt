package com.brianellissound.songitude.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Where the launch animation has got to. */
enum class SplashPhase { WAVES, FLYING, DONE }

private const val SPLASH_TILE_DP = 200f

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
    val scale = remember(resetToken) { Animatable(1f) }
    val dx = remember(resetToken) { Animatable(0f) }
    val dy = remember(resetToken) { Animatable(0f) }
    val backdrop = remember(resetToken) { Animatable(1f) }
    val tileAlpha = remember(resetToken) { Animatable(0f) }

    val latestTarget by rememberUpdatedState(logoTarget)
    val scope = rememberCoroutineScope()

    var rootSize by remember { mutableStateOf(Offset.Zero) }

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
            scope.launch { tileAlpha.animateTo(1f, tween(beat(0.35).toInt())) }
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
                .background(
                    Brush.radialGradient(
                        listOf(Color.Black, Color(0xFF121317), Color(0xFF4D525C)),
                    )
                )
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
            LogoTile(
                size = SPLASH_TILE_DP.dp,
                waveOpacity = { i -> waveOpacity(i, pulse) },
                tileOpacity = tileAlpha.value,
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
