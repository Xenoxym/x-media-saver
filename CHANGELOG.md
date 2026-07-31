# Changelog

All notable user-facing changes are recorded here. Version numbers follow Semantic Versioning.

## [Unreleased]

### Added

- Full-screen videos now support half-second long-press scrubbing: drag horizontally from the current playback position, see the target time and progress, then release to seek precisely. This works in both the media gallery and the native full-screen player opened from Post Preview.
- Double-tap the inner left or right side of a gallery video to seek backward or forward five seconds.
- Gallery video playback now uses the system player surface and offers user-initiated Picture in Picture without enabling automatic PiP on app backgrounding.

### Changed

- Gallery edge-tap navigation is limited to compact outer-edge zones and shows a subtle pressed gradient; releasing outside the original edge cancels the page change.
- Gallery edge-tap navigation now occupies exactly the outer one-tenth of each side, leaving more of the player surface for playback controls.
- Horizontal swipes now move the current media interactively with the finger, reveal the adjacent item, and settle only after crossing a distance or velocity threshold.
- Adjacent videos use a lightweight static preview during an interactive page drag; the real player is created only after the page becomes current.

### Fixed

- Returning from an upward-opened Post Preview no longer pauses the resumed gallery video after a short delay. Audio-session cleanup now runs only when the full-screen gallery itself closes.
- Full-screen media now covers the device safe areas without white bars. Video scrubbing starts only after the half-second long press completes, and its gesture no longer blocks quick edge taps or vertical/horizontal navigation.
- Interactive page covers now use the same centered fit as playback, and cancelled gestures automatically discard their temporary offset instead of leaving the gallery stuck between two items.
- Gallery headers again use the original edge-to-edge top position, adjacent covers are centered inside their own thumbnail container, and leaving the app can no longer start PiP unless the user first chose the system PiP control.
- A horizontal or vertical navigation direction is now locked for the full lifetime of each drag, preventing a slightly diagonal page swipe from opening Post Preview or dismissing the gallery.
- Preserve the locked swipe direction through `onEnded` so a horizontal drag that crosses the paging threshold actually commits; cancelled gestures still reset their offset automatically.
- After a page swipe, the centered cover remains above the new system player until `isReadyForDisplay` confirms its first frame, then disappears without animation to eliminate the black handoff flash without preloading videos.
- The first-frame cover now remains for one additional 20-millisecond render handoff, and Picture in Picture cleanup restores the native player control binding while rejecting background-triggered PiP starts.
- Gallery videos now use a public `AVPlayerLayer` with an app-owned control surface: play/pause, mute, progress seeking, and manual Picture in Picture remain above all empty-area gestures, and the unwanted native ±10-second controls are gone.
- Video edge taps use the outer one-seventh zones with pressed feedback and cancel-on-release-outside behavior. Inner double taps seek ±5 seconds without showing controls or feedback, while a half-second long press enables relative scrubbing with the existing progress overlay.
- Foreground gallery playback uses a non-background audio session and publishes no Now Playing metadata. The background playback category is activated only for user-started Picture in Picture or the explicit background-audio setting.
- Closing the full-screen media gallery now defers player-layer, observer, and Picture in Picture teardown until the dismissal transition has completed, avoiding the lifecycle race that could crash on either swipe-down or the close button.
- Video and animated-GIF covers no longer draw a play-button overlay. The gallery header sits below the device status area, and the custom play/pause control is geometrically centered.
- Background Audio now controls audio continuation only. Picture in Picture requires the in-player PiP button and rejects system-initiated background starts.
- Background Audio is now configured only in Settings; the duplicate Post Preview toggle has been removed. When enabled, both video surfaces detach before the app resigns active so only the player's audio continues and iOS has no inline video surface from which to auto-start PiP.
- Tapping the compact center play/pause area now toggles playback even when controls are hidden, while all surrounding tap, double-tap, scrub, and paging regions keep their existing behavior. The center control no longer draws a translucent black circle.
- The center play/pause target is refined to 100×100 points. Video controls fade away automatically after five seconds and remain hidden by default on entry and page changes.
- Indexed Posts places the media/text preview toggle beside the back button on the leading side. X Browser keeps its Sync button on one line when the loading spinner appears.
- All five Local Incremental Index destinations support a left-edge right swipe to return to Bookmarks without interfering with ordinary scrolling or center-originated gestures.
- Local Index edge-back recognition now owns only a 24-point leading strip, preventing short swipes from also activating an Indexed Post or media cell. Photo navigation locks one drag direction so diagonal horizontal paging cannot pull the image downward.
- Full-screen photos support double-tap zoom centered on the tapped location at 2.5×; double-tap again to return to the fitted view.

## [1.2.1] - 2026-07-29

### Added

- Indexed Posts now supports multi-select removal from the local Post index without deleting media already exported to Files or saved to Photos.

### Changed

- Browse and Search now defaults to the locally observed newest-bookmark order instead of newest publication date.
- Media-gallery drag selection requires a horizontal-leading gesture before vertical range selection, allowing ordinary vertical drags to keep scrolling.
- Indexed Posts uses a compact icon-only selection control in its crowded navigation toolbar.

### Fixed

- Once a horizontal-leading media selection drag activates, the gallery now holds its scroll position so subsequent vertical movement selects adjacent rows instead of scrolling the page.

## [1.2.0] - 2026-07-28

### Added

- English and Simplified Chinese UI with System, English, and Simplified Chinese language choices.
- A fourth Settings tab for language, storage/cache management, background audio, default Post preview style, version information, and the project link.
- Localized Photos add-only permission text for English and Simplified Chinese system languages.

### Changed

- Non-Chinese system languages now use English by default.
- Storage management moved from the Bookmarks toolbar into Settings.
- Localized cached navigation/back titles, range summaries, and browse-mode segments when switching languages.
- Simplified the animated-GIF filter label to “Animated GIFs (MP4)” and removed media-size analysis from the compact X Browser toolbar.
- Media-size analysis now uses three bounded concurrent probes instead of one serial request, while retaining lightweight HEAD/range metadata checks.
- Duration and size range controls use a language-neutral infinity symbol for an unlimited upper bound.

### Fixed

- Removed the experimental hidden-WebView sync path that could leave X Browser blank. Sync started from Bookmarks now switches to the visible X Browser, auto-scrolls there, and stops after six idle rounds or when the user leaves the tab.
- Media and indexed-Post pages use a compact chevron-only back button, avoiding stale localized titles and crowded navigation bars.

## [1.1.0] - 2026-07-27

### Added

- Preserve locally observed bookmark order and sort indexed posts or media galleries by newest/oldest bookmark position.
- Continue an active bookmark sync while the X WebView is offscreen inside the app.
- Browse photos, animated GIFs, videos, or all media in full screen with direct previous/next navigation.
- Multi-select media from the three-column gallery and save the selection to Photos.
- Adaptive muted autoplay for Post video previews, native full-screen playback, user-initiated Picture in Picture, and optional background audio.

### Improved

- Stabilized full-screen photo paging and removed transition animations that caused white flashes.
- Kept motion media on demand instead of maintaining a memory-heavy preload cache.
- Added reliable looping for short animated-GIF MP4s and Post preview videos.
- Serialized audio-session changes and tightened player lifecycle handling to reduce stalls when entering, leaving, or paging between media.
- Silent animated GIFs and videos no longer interrupt other audio solely to play.

### Technical limits

- Bookmark order reflects the order observed in X's bookmark timeline; X does not expose an exact bookmark-added timestamp through this workflow.
- Offscreen sync works only while iOS continues running the app and WebKit. It is not unrestricted system background execution.
- Picture in Picture depends on device support and iOS settings, and starts only through the native player control.
- The downloadable IPA is unsigned and must be signed locally before installation.

## [1.0.0] - 2026-07-27

- First stable release of the local-first X bookmark index, media browser, single-link downloader, Photos saver, and streaming Files export.

[1.1.0]: https://github.com/Xenoxym/x-media-saver/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Xenoxym/x-media-saver/releases/tag/v1.0.0
[Unreleased]: https://github.com/Xenoxym/x-media-saver/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/Xenoxym/x-media-saver/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Xenoxym/x-media-saver/compare/v1.1.0...v1.2.0
