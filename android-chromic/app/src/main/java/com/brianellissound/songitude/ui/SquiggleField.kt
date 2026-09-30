package com.brianellissound.songitude.ui

import androidx.compose.animation.core.withInfiniteAnimationFrameNanos
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.unit.dp
import com.brianellissound.songitude.R
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.random.Random

// Welcome's drifting squiggles, lifted out of FirstRunScreen so the Soundwalks list can share them
// (the iOS twin is `SquiggleField` in Brand.swift).

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
 *
 * Over the first-run scene (faded there behind the permission copy) and over the Soundwalks list,
 * between the wash and the cards. It has no pointer input, so it never takes a touch; the frame
 * clock is read only in the draw phase, so each frame is a redraw, never a recomposition.
 */
@Composable
fun SquiggleField(
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
