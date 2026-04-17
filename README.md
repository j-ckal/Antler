# Antler 🫎

Antler is a macOS menu bar app that shows:

- CPU usage/temperature
- Memory/swap usage and pressure
- Network latency

## Requirements

- An Apple Silicon mac
- macOS 14+
- Xcode

## Build and run

A pre-built signed binary is available in releases.

To build-at-home:

```bash
git clone https://github.com/j-ckal/Antler
cd Antler
BUILD_CONFIG=release ./Scripts/build-app.sh
```

This produces `dist/Antler.app`. Drag that to your Applications folder and open!

If you see *"App can't be opened because it is from an unidentified developer"*, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

To produce a Developer ID signed + notarized release build, first store your notarization credentials in keychain:

```bash
xcrun notarytool store-credentials antler-notary \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID \
  --password YOUR_APP_SPECIFIC_PASSWORD
```

Then run:

```bash
./Scripts/build-release.sh
```

That produces a signed, stapled `dist/Antler.app` and a distributable `dist/Antler.zip`. If you keep your certificate/profile in a non-default keychain, set `KEYCHAIN_PATH=/path/to/your.keychain-db` when storing credentials and when running the release build.

![Deer](deer.png)
