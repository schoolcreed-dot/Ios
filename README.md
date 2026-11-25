# Alpha Movies for iPhone — IPA build package

This repository contains an iOS SwiftUI/WebKit app based on the Alpha Movies v1.0.14 source. The GitHub Actions workflow builds for **physical iPhone** on macOS. The ZIP containing this repository is source code; an IPA is produced only after the workflow succeeds.

## Run the build

1. Extract all of this ZIP into the root of the iOS GitHub repository, including the hidden `.github` directory. Commit and push the files. The workflow must be on the repository's default branch to use **Run workflow**.
2. Open **Actions → Alpha Movies iOS IPA → Run workflow**.
3. Select **unsigned** to check compilation. Under the completed run's **Artifacts**, download **AlphaMovies-unsigned-IPA**. Its contents are an unsigned `AlphaMovies-UNSIGNED.ipa` and **cannot be installed on an iPhone or submitted to Apple**. The run also supplies an unsigned `.xcarchive`.
4. Select **signed** after configuring the Apple signing credentials below. Choose **app-store-connect** for TestFlight/App Store export or **ad-hoc** for a provisioning profile containing the intended test device IDs. Download **AlphaMovies-signed-IPA** from the completed run. It contains `AlphaMovies-SIGNED.ipa`.

A failed run includes **AlphaMovies-build-log** when Xcode reaches the archive step. Review the failed Actions step first.

## Signed build setup

Create an iOS App ID with **Push Notifications** enabled in your Apple Developer account. Prepare an Apple Distribution certificate exported as `.p12` with its private key and a **matching** App Store or Ad Hoc distribution provisioning profile with production APNs enabled. Register that same iOS bundle ID in Firebase and download its own `GoogleService-Info.plist`. Use your actual bundle ID instead of the example `ng.com.alphamovies.ios`.

In the GitHub repository, set **Settings → Secrets and variables → Actions**:

| Name | Type | Value |
| --- | --- | --- |
| `IOS_BUNDLE_ID` | Variable | Registered iOS bundle ID; defaults to `ng.com.alphamovies.ios` when omitted |
| `IOS_TEAM_ID` | Secret | Apple Developer Team ID |
| `IOS_P12_BASE64` | Secret | Base64 encoding of the Apple Distribution `.p12` file |
| `IOS_P12_PASSWORD` | Secret | Password used when exporting that `.p12` |
| `IOS_PROFILE_BASE64` | Secret | Base64 encoding of the matching `.mobileprovision` file |
| `IOS_FIREBASE_PLIST_BASE64` | Secret | Base64 encoding of the iOS app's `GoogleService-Info.plist` |

Encode files on a Mac with `base64 -i FILE | tr -d '\n'` and paste the output into the corresponding secret. Keep the certificate, private key, profile, and Firebase configuration out of the repository. The workflow checks for missing secrets and mismatched bundle IDs before building. An Ad Hoc IPA installs only on devices included in its profile; an App Store IPA is delivered through App Store Connect/TestFlight, not installed directly from the ZIP.

For local development on a Mac, install Xcode and XcodeGen, run `xcodegen generate`, open `AlphaMovies.xcodeproj`, choose your Apple team, and build on a simulator or iPhone. The signed export runs `xcodebuild archive` followed by `xcodebuild -exportArchive`.

## Before release

- Supply an approved iOS app icon and complete Apple store metadata. This package does not include an app icon.
- Test the website's login, playback, checkout, bank transfer, and movie downloads on a physical iPhone. WebKit rendering alone cannot establish that those flows work on iOS.
- Verify Firebase/APNs notification permission, token registration, delivery, and tap handling on a physical device; the existing WordPress registration endpoint may need iOS-specific server support.
- Check the site's subscription/payment implementation against the applicable App Store review requirements before submission. The workflow does not publish the app to Apple.

No Android or live WordPress files are modified by this package.
