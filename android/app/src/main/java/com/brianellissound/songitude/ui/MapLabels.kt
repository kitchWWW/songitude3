package com.brianellissound.songitude.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.Text
import coil.compose.AsyncImage
import com.brianellissound.songitude.model.CoordinateOffset
import com.brianellissound.songitude.model.Experience
import com.brianellissound.songitude.model.parseHexColor
import com.google.maps.android.compose.MarkerComposable
import com.google.maps.android.compose.rememberMarkerState

/**
 * Free-standing map markings: a caption on a plate, or a small image, pinned to one point and drawn
 * at a fixed screen size at every zoom. Purely visual — no audio, no containment test, no bearing
 * on playback of any kind.
 */
@OptIn(com.google.maps.android.compose.MapsComposeExperimentalApi::class)
@Composable
fun MapLabelOverlays(exp: Experience, offset: CoordinateOffset) {
    val labels = labelPositions(exp.map.drawableLabels, offset)
    for (dl in labels) {
        val l = dl.label
        val state = rememberMarkerState(key = "${l.id}@${dl.position.latitude},${dl.position.longitude}",
            position = dl.position)
        MarkerComposable(keys = arrayOf(l.id, l.image ?: l.text, l.bgColor, l.textColor),
            state = state) {
            val image = l.image
            if (image != null) {
                // Artwork is drawn at its authored width, aspect ratio kept.
                AsyncImage(
                    model = exp.imageFile(image),
                    contentDescription = l.name,
                    modifier = Modifier.width(l.size.dp),
                )
            } else if (l.hasPlate) {
                Text(
                    l.text,
                    modifier = Modifier
                        .background(
                            Color(parseHexColor(l.bgColor)),
                            RoundedCornerShape(6.dp),
                        )
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    color = Color(parseHexColor(l.textColor)),
                    fontSize = l.textSize.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            } else {
                // bgColor "none" ⇒ bare text, for a caption that should sit directly on the map.
                Text(
                    l.text,
                    color = Color(parseHexColor(l.textColor)),
                    fontSize = l.textSize.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
