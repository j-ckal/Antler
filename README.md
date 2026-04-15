# Antler 🫎

Antler is a macOS menu bar app that shows:

- CPU usage
- CPU temperature
- Memory usage and memory pressure

## Requirements

- An Apple Silicon mac
- macOS 14+
- Xcode

## Build and run

```bash
git clone https://github.com/j-ckal/Antler
cd Antler
BUILD_CONFIG=release ./Scripts/build-app.sh
```

This produces `dist/Antler.app`. Drag that to your Applications folder and open!

If you see *"App can't be opened because it is from an unidentified developer"*, go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.

![Deer](deer.png)