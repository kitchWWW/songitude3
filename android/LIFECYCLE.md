# Interruption and lifecycle audit — iOS ↔ Android

What happens to a walk in progress when the world interrupts it. Each row is the iOS behaviour,
what Android did, and what was done about it.

## Findings

| # | Situation | iOS | Android (before) | Resolution |
|---|---|---|---|---|
| L1 | **Pause from the lock screen, then resume** | Keeps its Now Playing entry at a playback rate of 0, so the control is still there to press. | Pausing stopped the foreground service, which took the notification with it. **A pause was effectively a stop** — nothing on the lock screen could start the walk again. | Fixed. Pausing now detaches the service from the foreground but leaves the notification standing, so the transport survives. Only "Stop" clears it. |
| L2 | **A notification chirp arrives** | Never interrupts. The walk plays on underneath. | Android reports this separately as `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK`, and it was treated as a full teardown — **the walk stopped dead because a message arrived**. | Fixed. Ducks to 25% for the duration and restores, which is what iOS effectively does (nothing). |
| L3 | **Bluetooth connects mid-walk** | Rebuilds the graph on `AVAudioEngineConfigurationChange`; playback continues on the new device. | Nothing. The `AudioTrack` was built for the old device and could be left rendering nowhere. | Fixed. `OnRoutingChangedListener` rebuilds the output with playback intact. |
| L4 | **Return to the app after it was frozen mid-teardown** | `handleForeground` makes the transport honest: if the engine isn't actually running, settle into paused so the button reads "play" and works. | Nothing. `isRunning` could keep claiming to play over silence, leaving a pause button that did nothing. | Fixed. `reconcileOnForeground()` on `onResume`. |
| L5 | **Lock-screen next / previous** | Explicitly disabled — *"Not a seekable medium"*. | Mapped to ±15s skip, offering controls iOS deliberately withholds. | Matched to iOS: play, pause and stop only. |
| L6 | **App swiped out of Recents** | A force-quit tears the session down and the walk stops. | The foreground service kept playing behind a notification the listener had just dismissed the app to be rid of. | Matched to iOS: `onTaskRemoved` stops playback. |
| L7 | **Phone call or Siri** | Interruption `.began` tears down and remembers; `.ended` with `.shouldResume` brings it back. | `AUDIOFOCUS_LOSS_TRANSIENT` → teardown, `GAIN` → resume. | Already equivalent. |
| L8 | **Another app takes audio permanently** | Interruption ends without `.shouldResume`: stop, and make `isRunning` honest rather than lying. | `AUDIOFOCUS_LOSS` → pause through the same path. | Already equivalent. |
| L9 | **Headphones unplugged** | Route change `.oldDeviceUnavailable` → pause, so a walk never blasts out of the speaker. | `ACTION_AUDIO_BECOMING_NOISY` → pause. | Already equivalent. |
| L10 | **Reopening the app while a walk plays** | Returns to the map, with its pause button. | Returned to the **walks list**: the Activity had been destroyed while the walk played, taking the ViewModel and the loaded walk with it, so the UI believed nothing was loaded. | Fixed. The loaded walk lives on the `Application` beside the engine, and is adopted on restart without disturbing playback. |
| L11 | **Reopening after a full quit** | Opens on the walks selector — `current` starts nil by design. | Same, now for the same reason: the process died, so there is nothing to adopt. | Already equivalent, deliberately. |

## No iOS bugs found in this pass

Every difference above was Android's. The one judgement call worth naming is **L6**: Android media
players commonly keep playing after a swipe-away, and an argument could be made for that here. It is
matched to iOS instead, because a soundwalk is a thing you are doing rather than a playlist you left
on, and dismissing the app is the clearest way of saying you have stopped walking.

## Still divergent, deliberately

Android's foreground-service notification has no iOS counterpart — the OS requires it to keep audio
and location alive with the screen off. It doubles as the lock-screen transport, which is the role
`MPNowPlayingInfoCenter` plays on iOS.
