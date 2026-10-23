# FlixQuest Custom Fork — AI & Developer Guide

This document provides complete architectural context, customization details, and operational workflows for any AI assistant (Android Studio Gemini / Studio Bot, GitHub Copilot, Cursor, etc.) or developer working on this codebase.

---

## 1. Repository Setup & Architecture

* **Official Upstream Repository**: `https://github.com/flixquest/flixquest.git` (`upstream`)
* **Personal Fork Repository**: `https://github.com/abhishekgt5360/flixquest.git` (`origin`)
* **Primary Working Branch**: **`custom-features`**
  * All customizations are maintained as clean commits on top of upstream releases.
  * **Rule**: Always create edits and commits on `custom-features` (do not commit directly to `main`).

---

## 2. Implemented Custom Features & File Map

### A. Local `.env` TMDB API Key Precedence
* **File**: `lib/constants/api_constants.dart`
* **Behavior**: The `TMDB_API_KEY` getter inspects `dotenv.env['TMDB_API_KEY']` first. If populated, it takes precedence over Firebase Remote Config (`_remoteTmdbApiKey`).
* **Environment**: Local `.env` is git-ignored and holds the user's private TMDB key.

### B. Indian Cinema & Indian Web Series Catalogues
* **Files**:
  * `lib/api/endpoints.dart`: Defines `Endpoints.indianMoviesUrl(page, l)` and `Endpoints.indianTVShowsUrl(page, l)` querying TMDB Discover with `&with_origin_country=IN&sort_by=popularity.desc`.
  * `lib/catalog/home_feed_controller.dart`: Adds `HomeList.indianCinema` to `KindRows`, fetches both movie and TV feeds.
  * `lib/mobile/screens/home_screen.dart`: Renders dedicated rows (`Indian Cinema & Movies` for movies, `Indian Web Series` for series).
  * `lib/mobile/widgets/genre_sheet.dart`: Adds a **Featured Catalogues** section at the top of the Categories sheet with selectable chips for Indian Cinema and Indian Web Series.
  * `assets/translations/en.json` & `assets/translations/hi.json`: Holds localized titles (`indian_movies`, `indian_series`, `featured_catalogues`).

### C. Real-Time Proxy Indicator Badge
* **File**: `lib/mobile/screens/home_screen.dart` (`_ProxyIndicator` inside `_HomeHeader`)
* **Behavior**:
  * Positioned immediately to the right of the `FLIXQUEST` logo in the top bar.
  * Renders as a rounded rectangular box with a 1.2px border:
    * **🔴 Red Border & Text (`#EF4444`)**: When `SettingsProvider.enableProxy == true` (TMDB requests are actively routing through the proxy server).
    * **🟢 Green Border & Text (`#10B981`)**: When `SettingsProvider.enableProxy == false` (Direct connection to TMDB is working smoothly, e.g., via Private DNS).
  * Uses `ExcludeSemantics` to ensure accessibility tap-target guidelines pass cleanly without interference.

### D. Ad Removal & Anti-Adblock Bypass
* **Files**: `lib/widgets/hosted_ads_banner.dart`, `lib/services/ad_service.dart`, `lib/mobile/screens/home_screen.dart`
* **Behavior**: Completely removes third-party banner ads, ad slots, and anti-adblock blocking modals for an ad-free streaming experience.

### E. Release Build Debug Signing Fallback
* **File**: `android/app/build.gradle`
* **Behavior**: If production release keystore properties are missing from local environment, the release build type automatically falls back to the debug signing config so release APKs can be built locally without requiring private keystores.

---

## 3. Build & Compilation Instructions

### Command to Build Production Release APK
```bash
flutter build apk --release --flavor prod
```
Output path: `build/app/outputs/flutter-apk/app-prod-release.apk`

### ⚠️ Critical Build Gotcha: Gradle Native Library Caching
* **Issue**: Flutter incremental builds (`flutter build apk`) may recompile Dart code into `.dart_tool/flutter_build/.../app.so`, but Gradle's `stripProdReleaseDebugSymbols` and `mergeProdReleaseNativeLibs` tasks can falsely report `UP-TO-DATE` and package stale `libapp.so` binaries into the final APK.
* **Fix**: If Dart UI or logic changes do not appear in the built APK:
  ```powershell
  Remove-Item -Recurse -Force build/app/intermediates
  Remove-Item -Recurse -Force build/app/outputs
  flutter build apk --release --flavor prod
  ```
  *(Or execute a full `flutter clean && flutter pub get` before building).*

---

## 4. How to Update from Upstream (Dev Releases)

When the original FlixQuest developers release a new update (e.g. `v4.2.4`, `v4.3.0`, or updates to `upstream/main`), rebase your custom features:

```bash
# 1. Fetch latest official changes
git fetch upstream

# 2. Rebase custom-features onto the new upstream main
git checkout custom-features
git rebase upstream/main

# 3. Resolve any conflicts (primarily in home_screen.dart or api_constants.dart)
# 4. Verify tests pass
flutter test test/home_screen_test.dart

# 5. Push updated custom-features to your fork
git push origin custom-features --force-with-lease

# 6. Rebuild APK
flutter build apk --release --flavor prod
```

---

## 5. Verification & Testing

* **Run Home Screen Test Suite**:
  ```bash
  flutter test test/home_screen_test.dart
  ```
* **Install onto Connected Android Phone via ADB**:
  ```bash
  adb install -r "build\app\outputs\flutter-apk\app-prod-release.apk"
  ```
* **Relaunch App**:
  ```bash
  adb shell "am force-stop dev.beamlak.flixquest_v2 && am start -n dev.beamlak.flixquest_v2/.MainActivity"
  ```
