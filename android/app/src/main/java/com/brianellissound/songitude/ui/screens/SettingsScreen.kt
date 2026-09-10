package com.brianellissound.songitude.ui.screens

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.brianellissound.songitude.AppAppearance
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.location.SongitudeLocationManager

/** The gear sheet: permission controls, reporting, appearance, credits and a hidden Debug section.
 *  Ported from ios/.../Views/SettingsView.swift. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(app: AppState, onClose: () -> Unit) {
    val context = LocalContext.current
    val auth by app.location.authorization.collectAsState()
    val appearance by app.appearance.collectAsState()
    val current by app.current.collectAsState()

    var showDebug by remember { mutableStateOf(false) }
    var confirmReset by remember { mutableStateOf(false) }
    var reporting by remember { mutableStateOf<ReportKind?>(null) }

    val walkName = current?.displayName
    val artistName = app.currentRemoteWalk?.creatorText?.takeIf { it.isNotEmpty() }
        ?: current?.map?.creator?.takeIf { it.isNotEmpty() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                actions = { IconButton(onClick = onClose) { Icon(Icons.Filled.Close, "Done") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()),
        ) {
            SectionHeader("Location")
            ListItem(
                headlineContent = { Text("Status") },
                trailingContent = {
                    Text(
                        when (auth) {
                            SongitudeLocationManager.Authorization.ALWAYS -> "Always"
                            SongitudeLocationManager.Authorization.WHEN_IN_USE -> "While using"
                            SongitudeLocationManager.Authorization.DENIED -> "Denied"
                            SongitudeLocationManager.Authorization.NOT_DETERMINED -> "Not set"
                        },
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
                    )
                },
            )
            ListItem(
                headlineContent = { Text("Open location settings") },
                modifier = Modifier.clickable {
                    context.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                            data = Uri.fromParts("package", context.packageName, null)
                        }
                    )
                },
            )

            SectionHeader("Report")
            // A greyed row reads as a broken button. With no walk open there is simply nothing to
            // name, so these two are absent rather than disabled.
            if (walkName != null) {
                ListItem(
                    headlineContent = { Text("Report $walkName") },
                    modifier = Modifier.clickable { reporting = ReportKind.WALK },
                )
            }
            if (artistName != null) {
                ListItem(
                    headlineContent = { Text("Report $artistName") },
                    modifier = Modifier.clickable { reporting = ReportKind.ARTIST },
                )
            }
            // Always offered: a bug report about the app itself doesn't depend on a loaded walk.
            ListItem(
                headlineContent = { Text("Report an issue") },
                modifier = Modifier.clickable { reporting = ReportKind.ISSUE },
            )

            SectionHeader("Appearance")
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                AppAppearance.entries.forEach { a ->
                    FilterChip(
                        selected = appearance == a,
                        onClick = { app.setAppearance(a) },
                        label = { Text(a.label) },
                    )
                }
            }

            SectionHeader("Credits")
            ListItem(
                headlineContent = { Text("Brian Ellis") },
                trailingContent = { Text("Creative Coder") },
                modifier = Modifier.clickable {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://brianellissound.com")))
                },
            )

            // Debug, hidden away behind a tap on its own header.
            ListItem(
                headlineContent = { Text("Debug", fontWeight = FontWeight.SemiBold) },
                modifier = Modifier.clickable { showDebug = !showDebug },
            )
            if (showDebug) {
                if (current != null) {
                    ListItem(
                        headlineContent = { Text("Re-center map over me") },
                        modifier = Modifier.clickable { app.recenterOnMe() },
                    )
                    ListItem(
                        headlineContent = { Text("Clear re-center") },
                        modifier = Modifier.clickable { app.clearRecenter() },
                    )
                }
                ListItem(
                    headlineContent = { Text("Reload walk catalog") },
                    modifier = Modifier.clickable { app.refreshCatalog() },
                )
                ListItem(
                    headlineContent = { Text("Reset App", color = MaterialTheme.colorScheme.error) },
                    modifier = Modifier.clickable { confirmReset = true },
                )
            }
            Spacer(Modifier.height(32.dp))
        }
    }

    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Reset Songitude?") },
            text = {
                Text(
                    "Clears preferences, downloaded walks and your progress, and returns to the first-run screen. " +
                        "Android won't let the app revoke its own location permission — that stays until you change it in system Settings."
                )
            },
            confirmButton = {
                TextButton(onClick = { confirmReset = false; app.resetEverything(); onClose() }) {
                    Text("Reset", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
        )
    }

    reporting?.let { kind ->
        ReportSheet(
            app = app,
            kind = kind,
            subjectName = when (kind) {
                ReportKind.WALK -> walkName
                ReportKind.ARTIST -> artistName
                ReportKind.ISSUE -> null
            },
            onClose = { reporting = null },
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        Modifier.padding(start = 16.dp, top = 20.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.6f),
    )
}
