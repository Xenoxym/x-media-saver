# Changelog

All notable user-facing changes are recorded here. Version numbers follow Semantic Versioning.

## [Unreleased]

### Added

- Full-screen videos now support half-second long-press scrubbing: drag horizontally from the current playback position, see the target time and progress, then release to seek precisely. This works in both the media gallery and the native full-screen player opened from Post Preview.
- Double-tap the inner left or right side of a gallery video to seek backward or forward five seconds.

### Changed

- Gallery edge-tap navigation is limited to compact outer-edge zones and shows a subtle pressed gradient; releasing outside the original edge cancels the page change.
- Horizontal swipes now move the current media interactively with the finger, reveal the adjacent item, and settle only after crossing a distance or velocity threshold.
- Adjacent videos use a lightweight static preview during an interactive page drag; the real player is created only after the page becomes current.

### Fixed

- Returning from an upward-opened Post Preview no longer pauses the resumed gallery video after a short delay. Audio-session cleanup now runs only when the full-screen gallery itself closes.
- Full-screen media now covers the device safe areas without white bars. Video scrubbing starts only after the half-second long press completes, and its gesture no longer blocks quick edge taps or vertical/horizontal navigation.

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
