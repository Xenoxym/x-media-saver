# X Media Saver

X Media Saver is a personal, sideloadable SwiftUI app for iOS 16 and later. Paste a public X/Twitter post URL, let the app resolve public media metadata directly from X, choose an MP4 variant (the highest bitrate is selected by default), download it on the iPhone, and save it to Photos.

There is no analytics, account login, cookie access, credential storage, custom backend, proxy, or third-party download API. GIF posts are supported when X exposes their usual MP4 representation.

## What is included

- Dependency-free SwiftUI app and complete Xcode project
- Public `x.com` and `twitter.com` URL validation
- Direct request to X's public embed/syndication host
- Highest-bitrate MP4 selection, with a manual quality picker
- Multiple video-media item selection when X returns more than one
- Quoted-public-post media fallback
- Download progress and cancellation
- Add-only Photos permission and direct Photos save
- Unit tests for URL parsing, MP4 ranking, HLS exclusion, GIF handling, quoted media, and photo-only rejection
- A shared Xcode scheme, app icon, and unsigned-IPA packaging script

## Build and run in Xcode

Requirements: macOS, Xcode 16 or newer recommended, and an iPhone or iPad running iOS/iPadOS 16 or later.

1. Open `XMediaSaver.xcodeproj`.
2. Select the **XMediaSaver** project, then the **XMediaSaver** target.
3. Under **Signing & Capabilities**, select your Apple Development team.
4. Change `com.example.XMediaSaver` to a bundle identifier unique to you, such as `com.yourname.XMediaSaver`.
5. Choose your connected iPhone and press Run.
6. On first save, choose **Allow Add Only** when Photos asks.

Run unit tests with **Product > Test** (`⌘U`).

## Create an IPA

### Option A: Xcode archive/export

1. Select **Any iOS Device (arm64)** or a connected iPhone as the run destination.
2. Choose **Product > Archive**.
3. In Organizer, select the archive and choose **Distribute App**.
4. Choose a local **Development** export (wording can vary by Xcode version), then export. Xcode creates an `.ipa`.

Apple documents that an archive can be exported for registered-device distribution and that the exported folder contains an `.ipa`: [Distributing your app to registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

### Option B: unsigned IPA for SideStore

SideStore signs apps itself. If Xcode's Organizer does not offer a convenient export for your account, open Terminal in this project directory and run:

```bash
bash Scripts/package-unsigned-ipa.sh
```

This creates `artifacts/XMediaSaver-unsigned.ipa`. The script builds an unsigned **device** binary, places the app in the standard `Payload` directory, and packages it as an IPA. It also saves the Xcode build log, binary inspection, IPA integrity check, and SHA-256 checksum under `artifacts/logs/`.

The unsigned IPA cannot be installed directly. SideStore or Sideloadly must sign it first.

## Build an unsigned IPA with GitHub Actions

The included `.github/workflows/build-unsigned-ipa.yml` runs on a GitHub-hosted macOS runner. It:

1. Records the macOS and Xcode versions.
2. Builds the Release configuration for `generic/platform=iOS` with code signing disabled.
3. Verifies that Xcode produced a device `.app` and Mach-O executable.
4. Packages the `.app` inside the standard `Payload/` IPA layout.
5. Tests the ZIP container and records its SHA-256 checksum.
6. Uploads the unsigned IPA and build logs as separate workflow artifacts for 14 days.

To run it:

1. Push this project to a GitHub repository with `XMediaSaver.xcodeproj` at the repository root.
2. Open the repository's **Actions** tab.
3. Select **Build unsigned IPA**.
4. Choose **Run workflow**.
5. When the job finishes, open its summary and download **XMediaSaver-unsigned-ipa**.
6. Download **XMediaSaver-build-logs-\<run number\>** if you need diagnostics.

Pushes to `main` that change the app, project, scripts, tests, or workflow also trigger a build.

### GitHub security boundary

Do not add an Apple ID, password, app-specific password, signing certificate, provisioning profile, API key, or other Apple credential to GitHub Actions secrets or repository files. The workflow deliberately uses:

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
CODE_SIGN_IDENTITY=""
```

GitHub only compiles and packages an unsigned device app. Download the artifact and perform signing locally. This keeps Apple account authentication and the resulting signing material off GitHub's runners and logs.

## Sign and install locally with Sideloadly

1. Download Sideloadly from [sideloadly.io](https://sideloadly.io/) on your own Windows or Mac.
2. Download `XMediaSaver-unsigned.ipa` from the GitHub Actions run.
3. Connect and trust the target iPhone or iPad.
4. Drag the IPA into Sideloadly.
5. Enter the Apple Account requested by Sideloadly **locally**, then start the sideload.
6. Follow the device prompts for Developer Mode and trusting the developer profile if required.

Sideloadly's current site describes this local flow as load IPA, enter an Apple ID, then sideload, and supports free or paid Apple accounts. Never enter those credentials into GitHub.

## Install with SideStore

1. Set up SideStore and LocalDevVPN using the official [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites) and [installation guide](https://docs.sidestore.io/docs/installation/install).
2. Transfer the exported or unsigned IPA to the iPhone (AirDrop, Files, iCloud Drive, or another local method).
3. Turn on Wi-Fi and LocalDevVPN.
4. Open SideStore, go to **My Apps**, tap the plus button, and select the IPA.
5. Keep the app refreshed within SideStore's signing window. A free Apple Account commonly shows a seven-day expiry in SideStore.

SideStore behavior and supported iOS versions can change, so defer to its current documentation.

## How media resolution works

1. The app extracts the numeric post ID locally.
2. It requests `https://cdn.syndication.twimg.com/tweet-result` directly from the device, including the embed route's non-secret placeholder token parameter. This host is used by X's public embed ecosystem, but the JSON endpoint is not a supported public developer API.
3. It reads `mediaDetails[].video_info.variants`, keeps HTTPS `video/mp4` entries hosted by `video.twimg.com`, and sorts by bitrate.
4. It downloads the chosen `video.twimg.com` URL directly.
5. It requests Photos **add-only** access and creates a video asset from the downloaded temporary file.
6. It deletes the temporary copy after saving.

Apple requires `NSPhotoLibraryAddUsageDescription` for write access and provides add-only authorization specifically for apps that only add assets: [usage-description key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryaddusagedescription), [add-only access](https://developer.apple.com/documentation/photos/phaccesslevel/addonly), and [creating a Photos video asset](https://developer.apple.com/documentation/photos/phassetchangerequest/creationrequestforassetfromvideo%28atfileurl%3A%29).

## Reliability and access limits

This boundary is deliberate and important:

- The app only resolves content X exposes to a logged-out public embed request. “The post opens in a browser” and “the embed JSON includes downloadable variants” are not equivalent.
- Public-looking posts can still be unavailable because of sensitive-media interstitials, age gates, country withholding, region restrictions, author/embed settings, deleted state, account state, or X's automated access controls.
- Private/protected posts, login-only posts, deleted posts, restricted posts, DMs, bookmarks, and authenticated timelines are unsupported.
- The app never imports browser cookies, extracts X app credentials, asks for a password, fabricates an authenticated session, or calls a service that may do those things on the user's behalf.
- A third-party download website may succeed where this app does not because that website uses its own server IP, cached metadata, authenticated accounts, unofficial guest-session machinery, or a proxy. Matching that behavior would violate this project's explicit no-backend/no-bypass boundary.
- The public syndication response has no published stability guarantee and can change or disappear without notice. A future X change may require an app update; there is no guaranteed backend-free fix.
- Only MP4 variants are downloaded. HLS playlists are ignored so the app does not need remuxing, FFmpeg, or background segment assembly.
- X-hosted MP4 URLs can expire or be revoked between metadata lookup and download.
- Downloads use a foreground URL session. Keep the app open for large files; background continuation is not guaranteed.
- Saving does not grant rights to reuse media. The user remains responsible for copyright, consent, and X's terms.

The `react-tweet` maintainers describe the same syndication route as unofficial and explicitly warn that it can break at any time: [discussion](https://github.com/vercel/react-tweet/issues/76). Their current fetcher still uses this host: [source](https://github.com/vercel/react-tweet/blob/main/packages/react-tweet/src/api/fetch-tweet.ts).

## Open-source reuse assessment

No existing implementation was copied into this project.

| Candidate | Why it was not reused |
| --- | --- |
| [Vercel react-tweet](https://github.com/vercel/react-tweet) | Useful evidence for the public syndication request, but it is a React/server rendering library, not an iOS downloader or Photos-saving implementation. |
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Mature extractor, but it is a large Python command-line system rather than a maintainable native Swift/iOS component. Its broader cookie/auth capabilities are intentionally outside scope. |
| [cobalt](https://github.com/imputnet/cobalt) | Trustworthy and well-known, but its own documentation describes a server API and recommends self-hosting; that directly conflicts with the no-custom-backend requirement. |
| Older iOS shortcuts/downloaders | Typically shortcut-only, unmaintained, closed-source, or dependent on external downloader websites; none met the full native/direct-save/no-backend requirement. |

The implementation is therefore small and original, using only Apple frameworks: SwiftUI, Foundation/URLSession, UIKit (clipboard/settings), and Photos.

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
    ├── build-unsigned-ipa.sh
    └── package-unsigned-ipa.sh
```

## Troubleshooting

- **Post unavailable:** Confirm it is public in a logged-out private browser window. Even then, the embed response may omit it.
- **No downloadable MP4:** The post may contain only photos, an external player/card, a live broadcast, or media X exposes only as HLS.
- **HTTP 403/404:** X declined the logged-out embed request; the app intentionally does not bypass it.
- **Photos denied:** Open iOS Settings, find **X Media Saver > Photos**, and grant add-only access.
- **SideStore install fails:** Ensure Wi-Fi and LocalDevVPN are on, the SideStore signing certificate is valid, and the bundle identifier does not collide with another installed app.

## License

MIT. See `LICENSE`.
