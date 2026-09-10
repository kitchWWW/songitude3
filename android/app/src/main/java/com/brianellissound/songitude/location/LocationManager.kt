package com.brianellissound.songitude.location

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.location.Location
import android.os.Build
import android.os.Looper
import androidx.core.content.ContextCompat
import com.brianellissound.songitude.model.LatLngD
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Wraps the fused location provider and the compass. Publishes permission state and the latest fix,
 * and keeps updates flowing while backgrounded so the audio engine can react in the user's pocket.
 *
 * Ported from ios/.../LocationManager.swift, with the same rule that matters most for privacy and
 * battery: high-accuracy updates run only while playback wants them. Opening the walks list takes a
 * single fix and stops.
 */
class SongitudeLocationManager(private val context: Context) : SensorEventListener {

    enum class Authorization { NOT_DETERMINED, DENIED, WHEN_IN_USE, ALWAYS }

    private val _authorization = MutableStateFlow(currentAuthorization())
    val authorization: StateFlow<Authorization> = _authorization.asStateFlow()

    private val _location = MutableStateFlow<LatLngD?>(null)
    val location: StateFlow<LatLngD?> = _location.asStateFlow()

    private val _heading = MutableStateFlow<Double?>(null)
    val heading: StateFlow<Double?> = _heading.asStateFlow()

    /** Called on every new fix so the owner can drive the audio engine. */
    var onLocation: ((LatLngD) -> Unit)? = null

    private val client: FusedLocationProviderClient =
        LocationServices.getFusedLocationProviderClient(context)
    private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    /** True while playback wants live fixes. The energy-intensive updates run only then. */
    private var wantsUpdates = false

    /** Set while a one-shot fix is outstanding. That fix updates [location] so the walks list can
     *  sort nearest-first, but is deliberately NOT forwarded to [onLocation] — opening a list must
     *  not drive the audio engine. */
    private var oneShotOnly = false
    private var oneShotHeading = false

    private val callback = object : LocationCallback() {
        override fun onLocationResult(result: LocationResult) {
            val loc = result.lastLocation ?: return
            deliver(loc)
        }
    }

    private fun deliver(loc: Location) {
        val coord = LatLngD(loc.latitude, loc.longitude)
        _location.value = coord
        if (oneShotOnly && !wantsUpdates) { oneShotOnly = false; return }
        onLocation?.invoke(coord)
    }

    fun refreshAuthorization() { _authorization.value = currentAuthorization() }

    private fun currentAuthorization(): Authorization {
        val fine = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        val coarse = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return Authorization.NOT_DETERMINED
        val background = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED
        } else true
        return if (background) Authorization.ALWAYS else Authorization.WHEN_IN_USE
    }

    val isAuthorized: Boolean
        get() = _authorization.value == Authorization.WHEN_IN_USE || _authorization.value == Authorization.ALWAYS

    /** Best guess at where we are WITHOUT starting updates. Used to sort the catalog nearest-first;
     *  never triggers a new request. */
    val lastKnownLocation: LatLngD? get() = _location.value

    /** One fix, then nothing. Used when the walks list opens so it can be ordered by distance even
     *  though playback isn't running. */
    @Suppress("MissingPermission")
    fun requestOneShotFix() {
        if (!isAuthorized || wantsUpdates) return
        oneShotOnly = true
        try {
            client.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                .addOnSuccessListener { loc -> if (loc != null) deliver(loc) }
            client.lastLocation.addOnSuccessListener { loc ->
                if (loc != null && _location.value == null) deliver(loc)
            }
        } catch (_: SecurityException) {
        }
        startHeading(oneShot = true)
    }

    /** Begin high-accuracy updates. Call when playback starts. */
    @Suppress("MissingPermission")
    fun start() {
        wantsUpdates = true
        if (!isAuthorized) return
        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 1000L)
            .setMinUpdateIntervalMillis(500L)
            // 3 m matches the iOS distanceFilter. A sound walk turns on where someone is standing,
            // so a coarser filter would let them walk into an area without it sounding.
            .setMinUpdateDistanceMeters(3f)
            .setWaitForAccurateLocation(false)
            .build()
        try {
            client.requestLocationUpdates(request, callback, Looper.getMainLooper())
        } catch (_: SecurityException) {
        }
        startHeading(oneShot = false)
    }

    /** Stop all updates. Call when playback pauses — releases GPS so a paused experience uses no
     *  location at all, foreground or background. */
    fun stop() {
        wantsUpdates = false
        client.removeLocationUpdates(callback)
        stopHeading()
    }

    // MARK: - Compass

    private var rotationSensor: Sensor? = null
    private val rotationMatrix = FloatArray(9)
    private val orientation = FloatArray(3)

    private fun startHeading(oneShot: Boolean) {
        if (rotationSensor != null) return
        val s = sensors.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR) ?: return
        oneShotHeading = oneShot
        rotationSensor = s
        sensors.registerListener(this, s, SensorManager.SENSOR_DELAY_UI)
    }

    private fun stopHeading() {
        rotationSensor?.let { sensors.unregisterListener(this) }
        rotationSensor = null
        oneShotHeading = false
    }

    override fun onSensorChanged(event: SensorEvent) {
        if (event.sensor.type != Sensor.TYPE_ROTATION_VECTOR) return
        SensorManager.getRotationMatrixFromVector(rotationMatrix, event.values)
        SensorManager.getOrientation(rotationMatrix, orientation)
        var deg = Math.toDegrees(orientation[0].toDouble())
        if (deg < 0) deg += 360.0
        _heading.value = deg
        if (oneShotHeading && !wantsUpdates) stopHeading()
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
