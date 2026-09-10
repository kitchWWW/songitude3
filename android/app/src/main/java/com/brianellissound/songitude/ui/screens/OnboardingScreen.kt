package com.brianellissound.songitude.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import com.brianellissound.songitude.ui.SongitudeMark
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp

/**
 * Onboarding is two screens, one per permission, each explaining what the app is about to ask for
 * and why — the same shape as the iOS pre-permission screen.
 *
 * Both advance buttons say "Continue", never "Enable" or "Allow". App Review rejected the older iOS
 * wording under Guideline 5.1.1(iv) for dressing a plain advance button up as consent: this screen
 * explains, the system prompt that follows decides.
 */
@Composable
private fun OnboardingStep(
    title: String,
    subtitle: String,
    body: String,
    footnote: String? = null,
    /** Screen one carries the logo; the splash flies its tile into this exact slot. */
    showLogo: Boolean = false,
    /** True while the splash still owns the logo. The slot reserves the space but draws nothing, so
     *  the incoming tile lands on an empty spot rather than on top of a duplicate. */
    hidesLogo: Boolean = false,
    onLogoBounds: (Rect) -> Unit = {},
    onContinue: () -> Unit,
    onNotNow: () -> Unit,
) {
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (showLogo) {
                Box(
                    Modifier
                        .size(100.dp)
                        .onGloballyPositioned { onLogoBounds(it.boundsInRoot()) }
                ) {
                    // The mark alone, no icon tile: the edge of a home-screen icon has no business
                    // on a screen that isn't the home screen. It takes the theme's own colour, so it
                    // reads on either background.
                    if (!hidesLogo) {
                        SongitudeMark(
                            Modifier.size(100.dp),
                            stroke = MaterialTheme.colorScheme.onBackground,
                        )
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
            Text(title, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            Text(subtitle, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))
            CopyBlock(body)
            if (!footnote.isNullOrBlank()) {
                Spacer(Modifier.height(16.dp))
                CopyBlock(footnote, bold = true)
            }
            Spacer(Modifier.height(40.dp))
            Button(onClick = onContinue, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Text("Continue")
            }
            Spacer(Modifier.height(12.dp))
            TextButton(onClick = onNotNow) { Text("Not now") }
        }
    }
}

/**
 * Renders a block of onboarding copy. A line beginning with "- " becomes a bullet, left-aligned so
 * the markers line up; everything else is a centred paragraph. Keeping both in one renderer means
 * the copy can be rewritten from prose to bullets and back without touching the layout.
 */
@Composable
private fun CopyBlock(text: String, bold: Boolean = false) {
    val lines = text.trim().lines()
    val weight = if (bold) FontWeight.SemiBold else FontWeight.Normal
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        var paragraph = StringBuilder()

        @Composable
        fun flush() {
            if (paragraph.isNotBlank()) {
                Text(
                    paragraph.toString().trim(),
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                    fontWeight = weight,
                )
            }
            paragraph = StringBuilder()
        }

        for (line in lines) {
            val t = line.trim()
            when {
                t.startsWith("- ") -> {
                    flush()
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 3.dp),
                        verticalAlignment = Alignment.Top,
                    ) {
                        Text("•", style = MaterialTheme.typography.bodyMedium, fontWeight = weight)
                        Spacer(Modifier.width(10.dp))
                        Text(
                            t.removePrefix("- "),
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = weight,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                t.isEmpty() -> {
                    flush()
                    Spacer(Modifier.height(10.dp))
                }
                else -> paragraph.append(if (paragraph.isEmpty()) t else " $t")
            }
        }
        flush()
    }
}

/** Step one: why the app needs to know where you are. */
@Composable
fun LocationOnboarding(
    hidesLogo: Boolean = false,
    onLogoBounds: (Rect) -> Unit = {},
    onContinue: () -> Unit,
    onNotNow: () -> Unit,
) = OnboardingStep(
    showLogo = true,
    hidesLogo = hidesLogo,
    onLogoBounds = onLogoBounds,
    title = "Songitude",
    subtitle = "music on the map",
    body = """
        - Your position changes the music you hear.
        - Songitude only uses your location locally on this phone.
        - It is never uploaded, stored or shared.
    """.trimIndent(),
    onContinue = onContinue,
    onNotNow = onNotNow,
)

/**
 * Step two: why the app needs to be allowed to post a notification.
 *
 * The wording is careful on purpose. Android will show a persistent playback control while a walk
 * runs — that is the mechanism that keeps the audio alive with the screen off — so promising "no
 * notifications" flatly would be a promise the app visibly breaks the first time you press play.
 * What it does promise is the thing people actually mean: nothing is ever pushed at you.
 */
@Composable
fun NotificationOnboarding(onContinue: () -> Unit, onNotNow: () -> Unit) = OnboardingStep(
    title = "One more thing",
    subtitle = "So the music keeps playing.",
    body = """
        - For the best experience, you might want to lock your phone and put it in your pocket.
        - In order to keep giving you location-accurate audio, we need permission to run in the background.
    """.trimIndent(),
    footnote = "We will never send you a notification. " +
        "Nothing is ever pushed at you — no alerts, no announcements, no reminders.",
    onContinue = onContinue,
    onNotNow = onNotNow,
)
