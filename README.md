# XMusic

XMusic is a simple iOS music player written in SwiftUI.

## Features

- Pick an iCloud Drive folder with the system folder picker.
- Scan and cache FLAC, APE, ALAC, M4A, and MP3 files.
- Persist the selected folder bookmark, play mode, and last refreshed song list.
- Play, pause, skip, refresh, and switch between list loop, single loop, and shuffle modes.
- Show per-song title, format, progress, elapsed time, and duration.

## Build

Open `XMusic.xcodeproj` in Xcode and run the `XMusic` scheme on an iPhone simulator or device.

APE files are included in the library scan. Playback depends on the codecs available through iOS media frameworks.
