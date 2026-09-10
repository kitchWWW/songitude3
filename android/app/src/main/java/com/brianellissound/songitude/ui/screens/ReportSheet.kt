package com.brianellissound.songitude.ui.screens

import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.brianellissound.songitude.AppState
import com.brianellissound.songitude.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

enum class ReportKind(val wire: String, val formTitle: String) {
    WALK("walk", "Report a soundwalk"),
    ARTIST("artist", "Report an artist"),
    ISSUE("issue", "Report an issue"),
}

/**
 * The reporting form. This is one of the four Guideline 1.2 safeguards the app declares, so it has
 * to actually reach a person: it posts to the same endpoint the iOS app uses, which emails the
 * report verbatim. No account, no identifier — just the text, which walk it is about, and enough
 * build detail to make a bug report actionable.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportSheet(app: AppState, kind: ReportKind, subjectName: String?, onClose: () -> Unit) {
    var message by remember { mutableStateOf("") }
    var sending by remember { mutableStateOf(false) }
    var sent by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val current by app.current.collectAsState()

    ModalBottomSheet(onDismissRequest = onClose) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 32.dp)) {
            Text(kind.formTitle, style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            if (kind == ReportKind.ISSUE && current == null) {
                Text(
                    "No soundwalk is loaded, so this will be sent without one attached.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
                Spacer(Modifier.height(8.dp))
            } else if (subjectName != null) {
                Text(subjectName, style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(8.dp))
            }

            if (sent) {
                Text("Your report has been sent. We read every one.")
                Spacer(Modifier.height(16.dp))
                Button(onClick = onClose) { Text("Done") }
            } else {
                Text("What should we know?", style = MaterialTheme.typography.labelLarge)
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = message,
                    onValueChange = { message = it },
                    modifier = Modifier.fillMaxWidth().height(160.dp),
                    placeholder = { Text("Tell us what happened") },
                )
                error?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    "Reports go straight to Songitude. Nothing about you is attached — no account, no identifier.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                )
                Spacer(Modifier.height(16.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(
                        enabled = !sending && message.isNotBlank(),
                        onClick = {
                            sending = true; error = null
                            scope.launch {
                                val result = ReportService.send(
                                    kind = kind,
                                    subjectName = subjectName,
                                    walkId = current?.id,
                                    artist = app.currentRemoteWalk?.creatorText,
                                    message = message,
                                )
                                sending = false
                                result.fold(
                                    onSuccess = { sent = true },
                                    onFailure = { error = "Couldn't send: ${it.message ?: "unknown error"}" },
                                )
                            }
                        },
                    ) { Text(if (sending) "Sending…" else "Send") }
                    TextButton(onClick = onClose) { Text("Cancel") }
                }
            }
        }
    }
}

object ReportService {
    private const val ENDPOINT = "https://omzhe5l8f5.execute-api.us-east-1.amazonaws.com"

    suspend fun send(
        kind: ReportKind,
        subjectName: String?,
        walkId: String?,
        artist: String?,
        message: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val body = JSONObject().apply {
                put("kind", kind.wire)
                put("subjectName", subjectName ?: "")
                put("walkId", walkId ?: "")
                put("artist", artist ?: "")
                put("message", message)
                put("appVersion", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
                put("device", "${Build.MANUFACTURER} ${Build.MODEL}, Android ${Build.VERSION.RELEASE}")
            }
            val conn = (URL(ENDPOINT).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                setRequestProperty("Content-Type", "application/json")
                doOutput = true
                connectTimeout = 20_000
                readTimeout = 20_000
            }
            conn.outputStream.use { it.write(body.toString().toByteArray()) }
            val code = conn.responseCode
            conn.disconnect()
            if (code in 200..299) Result.success(Unit)
            else Result.failure(IllegalStateException("the server refused it (HTTP $code)"))
        } catch (t: Throwable) {
            Result.failure(t)
        }
    }
}
