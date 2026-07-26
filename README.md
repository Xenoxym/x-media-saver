# X Media Saver

**English** | [简体中文](README.zh-CN.md)

X Media Saver is a personal, sideloadable SwiftUI app for iOS 16 and later. It keeps the original single-link video/GIF downloader and adds an authenticated, browser-session workflow for capturing media metadata from X bookmarks.

The app has no custom backend, proxy, or third-party download API. It does not use X OAuth, developer API keys, or user bearer tokens.

## Current features

- **Single-link downloads:** Paste an `x.com` or `twitter.com` post URL, select an MP4 variant, and save a video or animated GIF to Photos.
- **In-app X browser:** Sign in on the real X website inside a persistent `WKWebView`.
- **One-tap bookmark sync:** After signing in once, start synchronization from the native Bookmarks tab. The persistent WebView opens the X bookmarks page and scrolls automatically.
- **Media filters:** Select photos, animated GIFs, videos, or any combination.
- **Date filters:** Filter by the post publication date.
- **Session statistics:** Count captured bookmarks, bookmarks with media, photos, animated GIFs, and videos.
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
- keeps captured metadata in the current app session;
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

Statistics and batch downloads include only bookmark entries that the webpage actually loads. After the first browser login, the native **Sync** button drives the persistent WebView to the bookmarks page and scrolls it automatically. If the WebKit login session expires, the app asks the user to return to the browser and sign in again.

## Using bookmark batch saving

1. Open the **X Browser** tab once and sign in on the X website.
2. Return to the native **Bookmarks** tab.
3. Tap **Sync**. The app opens the X bookmarks page in its persistent WebView and scrolls automatically.
4. Select photos, animated GIFs, videos, and an optional publication-date range.
5. Tap **Batch download and save to Photos**.
6. Grant add-only Photos permission when prompted.

Duplicate captured media is removed by `media_key` before batch saving.

## Reliability and technical limits

- The browser workflow depends on X's undocumented web response structure. GraphQL operation names, response fields, or page behavior may change and require an app update.
- Login challenges, verification, and account-risk decisions remain entirely controlled by X.
- The captured bookmark count is a loaded-session count, not a guaranteed server-side total.
- Automatic synchronization stops after repeated rounds with no newly captured posts, or after its safety limit.
- The app saves direct X-hosted photos and MP4 variants. It does not assemble HLS streams, live broadcasts, or external card players.
- Large batches use foreground `URLSession` downloads; keep the app open.
- A WebKit session may expire or be cleared after system cleanup or sideloaded-app re-signing.
- Saving media does not grant redistribution rights. Users remain responsible for applicable law, copyright, consent, and X's terms.

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

## License

MIT. See `LICENSE`.
