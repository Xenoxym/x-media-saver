# Validation report

Validated on July 25, 2026 from the provided Windows environment.

## Passed

- Parsed every asset-catalog JSON file.
- Parsed `Info.plist` and confirmed it requests only `NSPhotoLibraryAddUsageDescription`, not Photos read access.
- Parsed the shared Xcode scheme as XML and confirmed Archive is enabled.
- Confirmed the 1024×1024 app icon is RGB and opaque.
- Checked the Xcode project structure, balanced object braces, app/test targets, and every Swift source membership.
- Checked that the Swift code directly uses X's syndication host, filters `video/mp4`, limits media URLs to `video.twimg.com`, and uses Photos `.addOnly`.
- Checked that Swift sources contain no FxTwitter/cobalt API, browser-cookie, `auth_token`, or web-view integration.
- Confirmed test coverage fixtures for animated GIFs, HLS exclusion, highest bitrate, quoted posts, tombstones, photo-only posts, and untrusted MP4 hosts.
- Parsed `.github/workflows/build-unsigned-ipa.yml` as YAML and confirmed:
  - `macos-15` runner
  - read-only repository contents permission
  - no GitHub secret consumption
  - separate IPA and build-log artifacts
  - build logs upload with `if: always()`
- Ran `bash -n` successfully against both IPA packaging scripts.
- Confirmed the CI script disables allowed, required, and identity-based code signing; targets `generic/platform=iOS`; expects `Release-iphoneos/XMediaSaver.app`; creates the standard `Payload` layout; tests the IPA container; and writes a SHA-256 checksum.
- Confirmed the CI files contain no Apple ID, Fastlane password, Match password, certificate-import, or provisioning-profile input.
- Live public-X check using X's developer-video post `1293593516040269825`:
  - Metadata HTTP status: `200`
  - Response type: `Tweet`
  - Media items: `1`
  - MP4 variants: `3`
  - Highest bitrate: `2,176,000`
  - Chosen host: `video.twimg.com`
  - Direct MP4 HEAD status: `200`
  - Content type: `video/mp4`
  - Content length: `2,386,447` bytes

## Not available in this environment

The host has no macOS, Xcode, iOS SDK, simulator, signing identity, iPhone Photos library, SideStore, or Sideloadly installation. Therefore an actual Xcode compile, XCTest run, archive/export, Photos permission prompt, on-device save, GitHub-hosted macOS workflow run, and local Sideloadly signing/install could not be executed here.

Before relying on the app, open it in Xcode on a Mac, select a signing team and unique bundle identifier, run `⌘U`, then test one public video and one public GIF on the target iPhone. The build and IPA instructions are in `README.md`.
