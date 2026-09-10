package com.brianellissound.songitude.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
    onContinue: () -> Unit,
    onNotNow: () -> Unit,
) {
    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(title, style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(12.dp))
            Text(subtitle, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center)
            Spacer(Modifier.height(32.dp))
            Text(body, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
            if (footnote != null) {
                Spacer(Modifier.height(16.dp))
                Text(
                    footnote,
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                    fontWeight = FontWeight.SemiBold,
                )
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

/** Step one: why the app needs to know where you are. */
@Composable
fun LocationOnboarding(onContinue: () -> Unit, onNotNow: () -> Unit) = OnboardingStep(
    title = "Songitude",
    subtitle = "Music composed onto a map.",
    body = "As you walk, your position decides which layers of the music you hear. Songitude uses " +
        "your location only on this phone, only while a walk is playing, to choose what sounds. " +
        "It is never uploaded, stored or shared, and no account is needed.",
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
    body = "A soundwalk is meant to be heard with the phone in your pocket and the screen off. " +
        "Android only lets an app keep audio and GPS running in the background if it can show a " +
        "playback control while it does — so Songitude needs permission to post one. It is also " +
        "how you pause from the lock screen.",
    footnote = "We will never send you a notification. Nothing is ever pushed at you — no alerts, " +
        "no announcements, no reminders. The only thing that appears is the playback control, and " +
        "only while a walk is actually playing.",
    onContinue = onContinue,
    onNotNow = onNotNow,
)
