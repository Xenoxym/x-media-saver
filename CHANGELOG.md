# Changelog

All notable user-facing changes are recorded here. Version numbers follow Semantic Versioning.

## [Unreleased]

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
[Unreleased]: https://github.com/Xenoxym/x-media-saver/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/Xenoxym/x-media-saver/compare/v1.1.0...v1.2.0
