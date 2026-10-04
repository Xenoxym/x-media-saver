# Temporary full-screen audio test

1. Open **Settings → Audio Comparison Test**, then choose a video from Files.
2. Tap **Play Full Screen**. Seek to an ASMR excerpt and tap **Mark Test Start**.
3. Open the top-right settings button, choose a preset, and tap **Apply and Replay**.
4. First compare A–E with both switches off. Then change one switch at a time.
5. Record the preferred preset and switches in **Listening Notes**.

| Preset | Category | Mode |
| --- | --- | --- |
| A | playback | moviePlayback |
| B | playback | default |
| C | ambient | default |
| D | soloAmbient | default |
| E | playback | spokenAudio |

C mirrors the gallery's foreground audio session with Background Audio off.
Mixing is configurable for playback presets; ambient already mixes by definition.
C/D follow the iPhone silent switch. The spatialization switch is an independent
test variable, not a presumed fix. Switching settings never replaces the video.

The test uses AVPlayer + AVPlayerLayer, has no inline preview, PiP, background
playback, media preloading, or Now Playing metadata. Leaving the test restores
the previous session configuration and deactivates the test session. Files are
opened read-only with security-scoped access, not copied or modified.

To remove: delete `AudioComparisonView.swift`, its four Xcode project references,
the Temporary Tests section in `SettingsView`, and the test localization keys.
Production players and their settings are unchanged.
