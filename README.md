# X Media Saver

**English** | [简体中文](README.zh-CN.md)

X Media Saver is a personal, sideloadable SwiftUI app for iOS 16 and later. It keeps the original single-link video/GIF downloader and adds an authenticated, browser-session workflow for capturing media metadata from X bookmarks.

The app has no custom backend, proxy, or third-party download API. It does not use X OAuth, developer API keys, or user bearer tokens.

Current release: **1.2.1 (build 9)**. See [CHANGELOG.md](CHANGELOG.md) for release history.

## Current features

- **Single-link downloads:** Paste an `x.com` or `twitter.com` post URL, select an MP4 variant, and save a video or animated GIF to Photos.
- **In-app X browser:** Sign in on the real X website inside a persistent `WKWebView`.
- **Fast incremental bookmark sync:** Bookmark scrolling starts only after the user taps **Sync bookmarks** in X Browser. The approximately one-second scroll loop observes every bookmark response; existing post IDs are updated in place, new IDs are appended, and locally indexed posts are not deleted merely because they disappeared from X.
- **Local post index:** Each captured post, its author/text/date, and its media metadata are stored on-device and restored after relaunch. Media files are downloaded only when Save is used.
- **Browse and search:** Browse the current filtered posts directly or group them by account or hashtag; search handle, display name, numeric user ID, post text, or hashtag.
- **Native post preview and saving:** Open a captured post to read its full text, preview original photos or highest-quality MP4 media, and save that post's deduplicated media directly to Photos.
- **Indexed-post timeline:** The Indexed Posts statistic opens a live, X-like stream of every locally indexed post. It defaults to media, supports bookmark/publication sorting and search, offers a remembered text-only mode, and can multi-select Posts for removal from the index without deleting exported media.
- **Media galleries:** The All media, Photos, Animated GIFs, and Videos counters open three-column lazy galleries.
- **Bookmark-order sorting:** Indexed posts and media galleries can follow the locally captured bookmark order in either direction, in addition to post publication time.
- **Full-screen media browsing:** Photos support zooming and panning; media galleries support direct previous/next navigation and multi-selection for saving to Photos.
- **Native video playback:** Post videos autoplay muted in an adaptive inline player, loop at the end, and use the native full-screen player with user-initiated Picture in Picture. Animated GIF MP4s loop silently.
- **Optional background audio:** Audible video can continue as audio only when the user enables background playback. Silent video does not occupy background audio playback.
- **English and Simplified Chinese UI:** Follow the system language or override it from the Settings tab. Chinese system languages use Simplified Chinese; all other system languages fall back to English.
- **Central Settings tab:** Manage language, storage and cache tools, background-audio behavior, the default indexed-Post preview style, and app/version information.
- **Local-first playback:** Preview lookup uses `media_key` to open an existing Files-library item first and falls back to the unchanged X CDN URL only when no local file exists.
- **Duration and size range sliders:** Choose discrete minimum and maximum bounds for video/GIF duration and aggregate Post media size. The rightmost maximum step means unlimited.
- **Batch storage estimates:** Sum the deduplicated known bytes for the current filter, report unknown-size items, and show separate estimated additions for Photos history and the app-owned Files Library.
- **Streaming Files export:** Save one media item at a time into a visible `Images / Animated GIFs / Videos` folder tree and write a line-oriented `posts.jsonl` manifest. No ZIP or whole-batch memory buffer is used.
- **Persistent duplicate protection:** Successful Photos saves and Files exports keep separate on-device `media_key` ledgers and skip completed media by default.
- **Storage management:** Inspect controlled storage categories and clear temporary, URLSession, and X WebKit caches without removing the X login cookie.
- **Media filters:** Select photos, animated GIFs, videos, or any combination.
- **Date filters:** Filter by the post publication date.
- **Local-index statistics:** Count indexed bookmarks, bookmarks with media, photos, animated GIFs, and videos.
- **Highest available quality:** Select the highest-bitrate MP4 by default and request X photos with `name=orig`.
- **On-device saving:** Download directly from X media hosts and add the files to Photos with add-only permission.
- **Batch progress and cancellation:** Continue past individual failures and report saved, skipped, and failed counts.

X distinguishes photo, video, and animated-GIF media objects. The app preserves that distinction for filtering and statistics. Animated GIFs are normally delivered by X as MP4 variants, so the app saves their highest-quality MP4 representation. See the [X media documentation](https://docs.x.com/x-api/media/introduction).

## What authenticated access currently means

Signing in does not give the native code unrestricted access to the account.

The X login page runs inside `WKWebView`. Credentials, verification codes, and challenges are submitted directly to X. WebKit's persistent website data store retains the website session. The native app:

- does not inspect password fields;
- does not query, copy, export, or upload cookies;
- does not extract authorization headers or account tokens;
- does not construct additional private X GraphQL/API requests;
- observes only X/Twitter `Bookmarks`, `BookmarkFolderTimeline`, and `TweetDetail` responses that the webpage itself has already loaded;
- keeps captured post/media metadata in the app's protected local Application Support directory;
- does not send captured data to a custom service.

The official X bookmarks API requires a user access token and OAuth. That API is intentionally not used here. See the [X bookmarks documentation](https://docs.x.com/x-api/posts/bookmarks/introduction).

Choosing **Sign out and clear** removes X/Twitter website data from this app's WebKit data store without affecting Safari. Apple documents that the default [`WKWebsiteDataStore`](https://developer.apple.com/documentation/webkit/wkwebsitedatastore) stores website data persistently.

## Important behavior clarifications

### Single-link mode

After signing in once, single-link mode automatically opens the pasted post in the same persistent WebView and waits for the X page's `TweetDetail` response. The user does not need to open the post manually in the browser first.

If a matching browser capture is unavailable, the app falls back to X's public syndication/embed response. That fallback is unofficial and may not resolve login-only content.

The current single-link screen saves videos and animated GIFs. Photo saving is currently available through the bookmark batch workflow.

### Protected and private content

The app can process media that the signed-in account is allowed to view and that the X webpage actually loads. This can include posts from protected accounts when the signed-in user has access.

It does not bypass X access controls. Deleted posts, inaccessible protected posts, direct messages, region/age restrictions, and content withheld from the signed-in browser session are not made accessible by the app.

### Photo quality

For photos, the parser converts X's `pbs.twimg.com` media URL to a request with `name=orig`. This asks X's image CDN for the original/highest available image represented by that media URL instead of a normal preview size.

This is separate from the X client's “Load in 4K” interface. The app does not simulate a long press or toggle that UI setting; it directly requests the original CDN variant. The result is still limited by what X retains and returns for that post.

### Bookmark range and one-click behavior

Date filtering uses each post's `created_at` publication time. X's captured bookmark response does not reliably provide the time when a post was added to bookmarks.

Statistics and batch downloads include only bookmark entries that the webpage has loaded at least once. Opening **X Browser** loads `x.com/home`; X redirects to login only when the persistent session has expired. Once authenticated, the app opens bookmarks and scrolls roughly once per second. It stops after repeated idle rounds with no new bookmark response.

The sync is append/update-only: post IDs already in the local index are not duplicated, newly observed IDs are added, and remote deletions do not remove local records. Photos saving also skips media that this version has previously recorded as successfully saved. Because older releases had no save ledger, the UI includes a migration action to mark the current filtered selection as already saved without downloading it.

## Using bookmark batch saving

1. Open the **X Browser** tab once and sign in on the X website.
2. The app opens X Home without scrolling. Tap **Sync bookmarks** when you want it to open bookmarks and begin automatic scrolling; tap **Stop** to end the current pass.
3. In **Bookmarks**, choose account/post/hashtag browsing and optionally search by account metadata, text, hashtag, publication date, duration, or media size.
4. Select photos, animated GIFs, videos, and an optional publication-date range.
5. Tap **Batch download and save to Photos**.
6. Grant add-only Photos permission when prompted.

Duplicate captured media is removed by `media_key` before batch saving.

## Streaming export to Files

The default destination appears under **On My iPhone > X Media Saver > Library**. A system folder picker can instead target another Files provider, including a user-selected iCloud Drive folder.

```text
Library/
├── Images/
├── Animated GIFs/
├── Videos/
├── posts.jsonl
└── export-state.jsonl
```

Each item is downloaded to a temporary file, moved into its type folder, recorded, and then followed by the next item. `posts.jsonl` maps post text/account/date data to local relative media paths so the captured post can be reconstructed offline. `export-state.jsonl` is append-only and allows interrupted or repeated exports to skip completed `media_key` values.

The default app-owned Library is indexed on demand for local-first previews. The media gallery uses fixed square, center-cropped cells in a stable three-column grid. Timeline and gallery thumbnails do not create permanent thumbnail files: local images are downsampled from their originals, local videos generate frames only for visible cells, and remote items request a small poster. A bounded in-memory cache is discarded when the app exits, preventing a second thumbnail library from consuming persistent storage.

Post video previews include an explicit native full-screen control. Picture in Picture starts only when the user chooses the native PiP control; leaving the preview does not automatically enter PiP.

## Reliability and technical limits

- The browser workflow depends on X's undocumented web response structure. GraphQL operation names, response fields, or page behavior may change and require an app update.
- Login challenges, verification, and account-risk decisions remain entirely controlled by X.
- The indexed bookmark count is a locally retained loaded count, not a guaranteed server-side total. X does not expose a reliable bookmark-added timestamp here.
- Bookmark-order sorting preserves the order in which entries were observed in the X bookmark timeline. It is useful for newest/oldest bookmark browsing but is not an exact bookmark-added timestamp.
- Synchronization captures network responses rather than rendered-cell counts. The faster scroll loop does not intentionally skip cursor pages, but no undocumented web workflow can guarantee a complete server-side inventory.
- Bookmark auto-scroll requires the X Browser tab to remain visible. Starting Sync from Bookmarks automatically switches to X Browser; leaving that tab stops the pass so WebKit is never moved into an unsupported hidden-view state.
- X bookmark JSON usually includes duration but not byte size. The app probes direct media CDN URLs with a limited, low-priority HEAD/range queue; unresolved values remain explicitly marked unknown.
- The storage screen can remove WebKit disk/memory/fetch caches while retaining cookies. Cookies and browser databases remain private by design and are never exported into Files.
- The app saves direct X-hosted photos and MP4 variants. It does not assemble HLS streams, live broadcasts, or external card players.
- Large batches use foreground `URLSession` downloads; keep the app open.
- A WebKit session may expire or be cleared after system cleanup or sideloaded-app re-signing.
- Saving media does not grant redistribution rights. Users remain responsible for applicable law, copyright, consent, and X's terms.
- The in-app language override applies to app UI. iOS-owned permission dialogs and native system controls continue to follow the device language.

## Build and run with Xcode

Requirements: macOS, Xcode 16 or later recommended, and an iPhone or iPad running iOS/iPadOS 16 or later.

1. Open `XMediaSaver.xcodeproj`.
2. Select the **XMediaSaver** target.
3. Choose your Apple Development team under **Signing & Capabilities**.
4. Replace `com.example.XMediaSaver` with a bundle identifier unique to you.
5. Select a connected device and run the app.
6. Use **Product > Test** to run the unit tests.

## Create an IPA

### Xcode archive

1. Select **Any iOS Device (arm64)** or a connected device.
2. Choose **Product > Archive**.
3. In Organizer, export a local Development build as an `.ipa`.

### Local unsigned IPA

Run from the project directory:

```bash
bash Scripts/package-unsigned-ipa.sh
```

The output is `artifacts/XMediaSaver-unsigned.ipa`. It must be signed locally by SideStore or Sideloadly before installation.

### GitHub Actions

`.github/workflows/build-unsigned-ipa.yml` runs on a GitHub-hosted macOS runner. It:

1. builds a Release device app with code signing disabled;
2. verifies the device Mach-O app and standard `Payload/` structure;
3. packages an unsigned IPA and records logs/checksums;
4. uploads the IPA and diagnostics as workflow artifacts.

Run **Actions > Build unsigned IPA > Run workflow**, then download the `XMediaSaver-unsigned-ipa` artifact.

Do not store an Apple ID, password, signing certificate, provisioning profile, API key, or other Apple credential in GitHub Secrets or repository files. GitHub only builds the unsigned app; signing remains local.

## Installation

- **SideStore:** Follow the [official SideStore installation guide](https://docs.sidestore.io/docs/installation/install), then select the IPA from Files.
- **Sideloadly:** Download it from [sideloadly.io](https://sideloadly.io/), import the IPA, and complete Apple-account signing locally.

## Project structure

```text
XMediaSaver/
├── .github/workflows/build-unsigned-ipa.yml
├── XMediaSaver.xcodeproj
├── XMediaSaver/
│   ├── Models/
│   ├── Services/
│   ├── ViewModels/
│   ├── Views/
│   ├── Resources/Assets.xcassets/
│   └── Info.plist
├── XMediaSaverTests/
└── Scripts/
```

The app uses Apple frameworks only: SwiftUI, Foundation/URLSession, WebKit, UIKit, and Photos.

## Release history

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT. See `LICENSE`.
