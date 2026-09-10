package com.brianellissound.songitude.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import kotlin.math.sqrt

/**
 * The Songitude mark drawn as vectors: a half globe on the left, three outward sound waves on the
 * right. Ported line for line from ios/.../Views/SongitudeMark.swift.
 *
 * Vector rather than a raster, for the same reason as on iOS: the splash animates the waves
 * individually, and the splash logo and the onboarding logo are literally the same drawing, which
 * is what makes the hand-off between them seamless.
 */
@Composable
fun SongitudeMark(
    modifier: Modifier = Modifier,
    /** Opacity for wave `i`, 0 being the innermost. Lets the splash pulse outward through them. */
    waveOpacity: (Int) -> Float = { 1f },
    stroke: Color = Color.White,
) {
    Canvas(modifier) {
        val s = minOf(size.width, size.height)
        val c = Offset(size.width / 2, size.height / 2)
        val r = s * 0.40f
        val lw = s * 0.058f
        val style = Stroke(width = lw, cap = StrokeCap.Round, join = StrokeJoin.Round)

        drawPath(globePath(c, r), color = stroke, style = style)

        for (i in 0 until 3) {
            drawPath(
                wavePath(c, r, i),
                color = stroke,
                alpha = waveOpacity(i).coerceIn(0f, 1f),
                style = Stroke(width = lw, cap = StrokeCap.Round),
            )
        }
    }
}

/** Left hemisphere: outer arc, the flat meridian edge, two latitudes and one bulging meridian. */
private fun globePath(c: Offset, r: Float): Path = Path().apply {
    // Angles run clockwise from +x with y pointing down, so 90° through 270° sweeps the left half.
    arcTo(Rect(c.x - r, c.y - r, c.x + r, c.y + r), 90f, 180f, true)

    moveTo(c.x, c.y - r)
    lineTo(c.x, c.y + r)

    for (dy in listOf(-0.36f * r, 0.36f * r)) {
        val halfWidth = sqrt(maxOf(0f, r * r - dy * dy))
        moveTo(c.x - halfWidth, c.y + dy)
        lineTo(c.x, c.y + dy)
    }

    moveTo(c.x, c.y - r)
    cubicTo(
        c.x - 0.78f * r, c.y - 0.52f * r,
        c.x - 0.78f * r, c.y + 0.52f * r,
        c.x, c.y + r,
    )
}

/** One of the three concentric waves: wider arcs the further out they sit. */
private fun wavePath(c: Offset, r: Float, index: Int): Path {
    val radii = floatArrayOf(0.38f, 0.69f, 1.0f)
    val spans = floatArrayOf(52f, 66f, 78f)
    val rr = r * radii[index]
    val span = spans[index]
    return Path().apply {
        arcTo(Rect(c.x - rr, c.y - rr, c.x + rr, c.y + rr), -span, span * 2, true)
    }
}

/** The app-icon tile: the mark on its black-metal gradient, rounded like the launcher icon. */
@Composable
fun LogoTile(
    size: Dp,
    modifier: Modifier = Modifier,
    waveOpacity: (Int) -> Float = { 1f },
    /** Fade of the tile itself. The splash starts at 0 so the mark floats on its own backdrop with
     *  no hard icon edges, then fades the tile in as it flies to the onboarding logo's slot. */
    tileOpacity: Float = 1f,
    cornerFraction: Float = 0.22f,
) {
    Box(
        modifier
            .size(size)
            .clip(RoundedCornerShape(size * cornerFraction)),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.linearGradient(
                        listOf(Color(0xFF3B3D45), Color(0xFF030303)),
                    )
                )
                .alpha(tileOpacity)
        )
        SongitudeMark(Modifier.size(size * 0.68f), waveOpacity = waveOpacity)
    }
}
