# GeckoView browser integration

The browser module uses Mozilla GeckoView 159.0.20261022150525 (ARM64).
The player plugin and Godot Android export include this module and its pinned engine.

- Project: https://firefox-source-docs.mozilla.org/mobile/android/geckoview/
- Artifact: https://maven.mozilla.org/maven2/org/mozilla/geckoview/geckoview-arm64-v8a/159.0.20261022150525/
- Upstream revision, from the published POM: `5add844c26613d7e4d84c799d6e23cf987b1240d`
- Corresponding source: https://hg.mozilla.org/releases/mozilla-release/rev/5add844c26613d7e4d84c799d6e23cf987b1240d
- Java sources: https://maven.mozilla.org/maven2/org/mozilla/geckoview/geckoview/159.0.20261022150525/geckoview-159.0.20261022150525-sources.jar
- License: Mozilla Public License 2.0; see LICENSE-MPL-2.0.txt. Preserve upstream third-party notices when packaging the engine.
- ARM64 AAR: 91,438,730 bytes; SHA-256 `fe774fc331941c8d9bab342426286ca168420de0a1d763eead64bb64191925a8`, verified against Mozilla's published Gradle module metadata.

Do not strip the AAR's SDK requirements to make it build: the published artifact
requires compile SDK 37.2. Its POM also declares Kotlin stdlib 2.4.20 and Media3
1.11.1. The build uses AGP 9.3.3, Gradle 9.5.0 and Kotlin 2.4.21 with compile SDK
37.2. Device min/target SDK remain controlled by the existing platform presets.
Final APK notices and distribution review remain required before publication.
