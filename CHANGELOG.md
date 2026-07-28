# Changelog

All notable user-facing changes are recorded here. Version numbers follow Semantic Versioning.

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
