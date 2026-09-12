package com.brianellissound.songitude.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import com.brianellissound.songitude.AppAppearance

/** Songitude is black-and-white with one accent blue, matching the iOS rebrand. */
private val Accent = Color(0xFF2E6BFF)

private val Light = lightColorScheme(
    primary = Accent,
    onPrimary = Color.White,
    background = Color(0xFFFFFFFF),
    onBackground = Color(0xFF111111),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF111111),
)

private val Dark = darkColorScheme(
    primary = Accent,
    onPrimary = Color.White,
    background = Color(0xFF0E0E10),
    onBackground = Color(0xFFF2F2F4),
    surface = Color(0xFF17171A),
    onSurface = Color(0xFFF2F2F4),
)

@Composable
fun SongitudeTheme(appearance: AppAppearance, content: @Composable () -> Unit) {
    val dark = when (appearance) {
        AppAppearance.SYSTEM -> isSystemInDarkTheme()
        AppAppearance.LIGHT -> false
        AppAppearance.DARK -> true
    }
    // The system bars are transparent and drawn over, so their icon colour has to follow the
    // theme, not the window: left alone they stay white and vanish on the light screens.
    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as? android.app.Activity)?.window ?: return@SideEffect
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }
    MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}

/** Whether the theme currently resolves to dark, for the map basemap choice. */
@Composable
fun isDarkTheme(appearance: AppAppearance): Boolean = when (appearance) {
    AppAppearance.SYSTEM -> isSystemInDarkTheme()
    AppAppearance.LIGHT -> false
    AppAppearance.DARK -> true
}
