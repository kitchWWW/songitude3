package com.brianellissound.songitude.ui.screens

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import kotlinx.coroutines.delay
import kotlin.math.sin

/** The launch animation: concentric waves spreading from the centre, then the wordmark.
 *  Shown once per install, like the iOS SplashRootView. */
@Composable
fun SplashScreen(onDone: () -> Unit) {
    val transition = rememberInfiniteTransition(label = "waves")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2200, easing = LinearEasing)),
        label = "phase",
    )
    LaunchedEffect(Unit) {
        delay(1800)
        onDone()
    }
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            val accent = MaterialTheme.colorScheme.primary
            Canvas(Modifier.fillMaxSize()) {
                val c = Offset(size.width / 2, size.height / 2)
                val maxR = size.minDimension * 0.45f
                for (i in 0 until 4) {
                    val t = ((phase + i / 4f) % 1f)
                    val r = maxR * t
                    val alpha = (1f - t) * 0.5f
                    drawCircle(
                        color = accent.copy(alpha = alpha),
                        radius = r,
                        center = c,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(width = 3f),
                    )
                }
            }
            Text(
                "Songitude",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}
