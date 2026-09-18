package com.brianellissound.songitude.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp

/**
 * The small Markdown subset the editor lets an author write: headings, bullet lists, block quotes,
 * bold, italic and links.
 *
 * iOS renders `about` and artist bios as real Markdown, so stripping the markers here left Android
 * showing flatter text than the same walk shows on an iPhone — headings collapsed into paragraphs
 * and lists losing their shape. This keeps the two readable the same way without pulling in a
 * Markdown library for six constructs.
 */
@Composable
fun MarkdownBody(
    source: String,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.onSurface,
    style: TextStyle = MaterialTheme.typography.bodyMedium,
) {
    val linkColor = MaterialTheme.colorScheme.primary
    Column(modifier) {
        var first = true
        for (block in source.trim().lines()) {
            val line = block.trimEnd()
            if (line.isBlank()) { Spacer(Modifier.height(8.dp)); continue }
            if (!first) Spacer(Modifier.height(4.dp))
            first = false

            val heading = Regex("^(#{1,6})\\s+(.*)$").find(line)
            when {
                heading != null -> {
                    val level = heading.groupValues[1].length
                    Text(
                        inline(heading.groupValues[2], linkColor),
                        style = when (level) {
                            1 -> MaterialTheme.typography.titleLarge
                            2 -> MaterialTheme.typography.titleMedium
                            else -> MaterialTheme.typography.titleSmall
                        },
                        fontWeight = FontWeight.Bold,
                        color = color,
                    )
                }
                line.startsWith("> ") -> {
                    Row(Modifier.fillMaxWidth()) {
                        // A quote bar rather than an indent, so it reads as a quote at a glance.
                        Text("│", color = color.copy(alpha = 0.4f), style = style)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            inline(line.removePrefix("> "), linkColor),
                            style = style.copy(fontStyle = FontStyle.Italic),
                            color = color.copy(alpha = 0.85f),
                        )
                    }
                }
                Regex("^\\s*[-*+]\\s+").containsMatchIn(line) -> {
                    Row(Modifier.fillMaxWidth().padding(start = 2.dp)) {
                        Text("•", style = style, color = color)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            inline(line.replaceFirst(Regex("^\\s*[-*+]\\s+"), ""), linkColor),
                            style = style,
                            color = color,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                Regex("^\\s*\\d+[.)]\\s+").containsMatchIn(line) -> {
                    val marker = Regex("^\\s*(\\d+)[.)]\\s+").find(line)!!.groupValues[1]
                    Row(Modifier.fillMaxWidth().padding(start = 2.dp)) {
                        Text("$marker.", style = style, color = color)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            inline(line.replaceFirst(Regex("^\\s*\\d+[.)]\\s+"), ""), linkColor),
                            style = style,
                            color = color,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                else -> Text(inline(line, linkColor), style = style, color = color)
            }
        }
    }
}

/** Bold, italic and links within one line. */
private fun inline(text: String, linkColor: Color): AnnotatedString = buildAnnotatedString {
    // Links first: their label can itself contain emphasis, and consuming them up front keeps the
    // emphasis scanner from tripping over the URL's own punctuation.
    val link = Regex("\\[([^\\]]+)]\\(([^)]+)\\)")
    var cursor = 0
    for (m in link.findAll(text)) {
        emphasis(text.substring(cursor, m.range.first))
        withLink(
            LinkAnnotation.Url(
                m.groupValues[2],
                TextLinkStyles(SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)),
            )
        ) { emphasis(m.groupValues[1]) }
        cursor = m.range.last + 1
    }
    emphasis(text.substring(cursor))
}

private fun androidx.compose.ui.text.AnnotatedString.Builder.emphasis(text: String) {
    var i = 0
    while (i < text.length) {
        val bold = text.indexOf("**", i)
        if (bold >= 0) {
            val close = text.indexOf("**", bold + 2)
            if (close > bold) {
                append(text.substring(i, bold))
                pushStyle(SpanStyle(fontWeight = FontWeight.Bold))
                append(text.substring(bold + 2, close))
                pop()
                i = close + 2
                continue
            }
        }
        val italic = Regex("(?<![*_])[*_](?![*_])(.+?)(?<![*_])[*_](?![*_])").find(text, i)
        if (italic != null) {
            append(text.substring(i, italic.range.first))
            pushStyle(SpanStyle(fontStyle = FontStyle.Italic))
            append(italic.groupValues[1])
            pop()
            i = italic.range.last + 1
            continue
        }
        append(text.substring(i))
        return
    }
}
