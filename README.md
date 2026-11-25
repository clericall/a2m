# MusicDrop

MusicDrop is a rootless iOS tweak that adds an **Add Music** button to the stock Music app. It imports DRM-free audio files from the Files app and can download supported audio from a URL. Files are copied locally, inspected with `AVFoundation`, and handed to Music's own import queue.

The package is built and published with GitHub Actions. The Sileo repository is hosted on GitHub Pages.

## Scope

MusicDrop does not bypass DRM, extract Spotify audio, or upload user files anywhere. Spotify links are resolved to a track title using Spotify's public oEmbed endpoint, then matched to a YouTube video. Spotify's own encrypted audio is never accessed.

Direct HTTPS downloads work without extra packages. YouTube downloads require FFmpeg and Python 3 (both available from `https://apt.procurs.us/`). MusicDrop fetches its own yt-dlp zipapp automatically and runs it with `python3`, since iOS will not execute a standalone downloader binary. Use them only for media you are allowed to save.

When FFmpeg is installed, MusicDrop looks up lyrics on [LRCLIB](https://lrclib.net) using the track's title, artist, album, and duration. The result is embedded into the audio file and saved as a sidecar in `/var/mobile/Media/MusicDrop/lyrics/`. The audio is never uploaded; only those four metadata fields are sent.

iOS 10 and later do not read embedded lyrics for local files — the native Lyrics view is fed by Apple Music's catalog. MusicDrop hooks `MPNowPlayingContentItem`'s `lyrics` and `hasLyrics` methods and returns a user-provided `MPNowPlayingInfoLyricsItem` built from the saved plain-lyrics sidecar. That makes Music's own Lyrics button show lyrics for local and downloaded songs. If FFmpeg is missing, no lookup happens. If LRCLIB has no match, the song imports normally without lyrics.

If the patch ever causes instability, create an empty file at `/var/mobile/Media/MusicDrop/disable_lyrics_patch` with Filza and restart Music to disable it.

iOS does not allow the Music app to launch external binaries. YouTube downloads and lyrics therefore run in a small rootless LaunchDaemon (`com.musiccc.musicdropd`) that ships inside the package. The tweak sends requests to it over `127.0.0.1:45454`. The daemon is started by the post-install script and at every boot.

## Requirements

- Rootless jailbreak on iOS 15.0–16.7.x
- MobileSubstrate or ElleKit
- Sileo or another package manager that supports `iphoneos-arm64`
- DRM-free audio files the user is allowed to import
- Optional for YouTube downloads: FFmpeg and Python 3 (for example from `https://apt.procurs.us/`). MusicDrop downloads its own yt-dlp zipapp automatically; an installed yt-dlp package is only a fallback.
- Optional for lyrics: rootless FFmpeg
- The bundled `musicdropd` LaunchDaemon must be allowed to run by the jailbreak

The build target is iPhone X on palera1n rootless. Other rootless setups may work but are not separately tested.

## Install

After the GitHub Actions workflow succeeds, the repository URL is:

```text
https://<owner>.github.io/<repo>/
```

For example:

```text
https://clericall.github.io/a2m/
```

On the device:

1. Open Sileo.
2. Add the repository URL under **Sources**.
3. Install **MusicDrop**.
4. Let Sileo respring or relaunch Music.
5. Open Music and wait a moment for the pink floating button to appear.

Tapping the button opens a menu:

- **Import Files** — choose one or more local files.
- **Download URL** — enter a direct audio URL, a YouTube URL, or a Spotify track link.
- **Search by Name** — find a YouTube video by song or artist name.
- **Batch Download** — paste several URLs, one per line, and download them in order.
- **Fix Lyrics** — scan songs already in your library (or pick files) and embed lyrics from LRCLIB.
- **Settings** — audio format, lyrics/artwork toggles, and cache cleanup.
- **Help** — quick explanation of each option.

Keep Music in the foreground during imports. MusicDrop requests background time, but the local file server runs inside the Music process and may be suspended.

## GitHub Pages setup

1. Create a public GitHub repository. Private repositories need a paid plan for Pages.
2. Push the project to the default branch (`main` or `master`).
3. In repository settings, set **Pages → Build and deployment → Source** to **GitHub Actions**.
4. Run **Build and publish MusicDrop** in the Actions tab, or push a commit.

The workflow:

- installs Theos and an iOS SDK on a macOS runner;
- builds the rootless `.deb`;
- generates `docs/Packages`, `docs/Release`, and compressed indexes;
- commits the generated index with `[skip ci]`;
- deploys `docs/` to GitHub Pages.

No repository URL is hard-coded in the tweak. The workflow derives it from `github.repository_owner` and the repository name.

If the workflow cannot commit the generated index, check that `GITHUB_TOKEN` has `contents: write`. Protected branches and organization policies can also block the push.

## Usage notes

- Multiple files can be selected at once. They are imported serially.
- The button can be dragged anywhere in the safe area. Its position is stored in `NSUserDefaults`.
- Direct URL downloads accept MP3, M4A, AAC, ALAC, WAV, AIFF, CAF, FLAC, MP4, M4V, and MOV responses up to 500 MB.
- Direct URL downloads reject HTML, unsupported formats, empty files, oversized files, non-HTTPS URLs, and private/local hosts.
- YouTube downloads are single items, not playlists. They are converted to M4A and limited to 500 MB.
- The helper fetches a pure-Python `yt-dlp` zipapp (v2025.10.14, the newest release compatible with Python 3.9) from GitHub on first use and refreshes it weekly, stored in `/var/mobile/Media/MusicDrop/bin/yt-dlp`. It is run with `/var/jb/usr/bin/python3`. An installed yt-dlp package is only a fallback. A standalone Mach-O binary cannot be used: iOS kills it with SIGKILL.
- Spotify track links are resolved to a title via Spotify's public oEmbed endpoint, then downloaded from the first matching YouTube result. Spotify's own encrypted audio is never accessed. If resolution fails, use **Search by Name**.
- **Fix Lyrics** scans `/var/mobile/Media/iTunes_Control/Music` plus MusicDrop's own folders, embeds lyrics in place with FFmpeg, and reports how many songs were updated. Restart Music afterward so it reloads the files. You can also pick files from Files instead.
- With FFmpeg installed, lyrics are fetched from LRCLIB and embedded into the audio file. They appear in Music under the Now Playing lyrics view. Songs without a lyrics match still import normally.
- Files without embedded artwork get a generated MusicDrop cover.
- Metadata is read with `AVAsset`: title, artist, album, album artist, genre, composer, year, track number/count, duration, and artwork.
- Imported songs are added to the normal Music library. Uninstalling MusicDrop does not remove them.

## Supported formats

Import and direct download support:

- Audio: MP3, M4A, AAC, ALAC, WAV, AIFF, CAF, FLAC, M4R, M4B
- Video: MP4, M4V, MOV

OGG, Opus, WMA, APE, and other formats that iOS Music cannot decode are rejected. Convert them to MP3 or M4A first.

## Files and directories

- `/var/mobile/Media/MusicDrop/inbox/` — copied input files
- `/var/mobile/Media/MusicDrop/artwork/` — generated/resized artwork
- `/var/mobile/Media/MusicDrop/downloads/` — URL download outputs
- `/var/mobile/Media/MusicDrop/tmp/` — temporary conversion files
- `/var/mobile/Media/MusicDrop/bin/` — downloaded yt-dlp zipapp
- `/var/mobile/Media/MusicDrop/musicdrop.log` — log file

Input, artwork, downloads, and temporary files are pruned after seven days. The log rotates to `musicdrop.log.old` at 1 MB.

## How it works

1. A constructor installs a floating `UIButton` in Music's key window.
2. Local import uses `UIDocumentPickerViewController` with audio and movie UTIs and `asCopy:YES`.
3. URL downloads use `NSURLSession` for direct files or `yt-dlp`/FFmpeg for YouTube.
4. Local files are copied into the MusicDrop inbox with a random token name.
5. `AVURLAsset` reads duration, tags, and artwork. Artwork is resized to JPEG or replaced with a generated cover.
6. `MDLyrics` queries LRCLIB with the track metadata and uses FFmpeg to embed the result as an ID3 `USLT` frame (MP3) or `©lyr` atom (M4A/MP4). This is what the Music app reads for its lyrics view.
7. A loopback HTTP server serves the registered file and artwork tokens with byte-range support.
8. `StoreServices` is loaded with `dlopen`. MusicDrop builds `SSDownloadMetadata`, wraps it in an `SSDownload`, and adds it to an `SSDownloadQueue`.
9. Music's store daemon fetches the loopback URL and adds the media to the library.

The private StoreServices code is isolated in `MDImporter.m`. The rest uses public UIKit, Foundation, and AVFoundation APIs.

## Troubleshooting

### The button does not appear

Check:

- MusicDrop is installed in Sileo.
- Tweak injection works for other tweaks.
- Music was fully closed and reopened after installation.
- `/var/jb/Library/MobileSubstrate/DynamicLibraries/MusicDrop.dylib` exists.
- `/var/jb/Library/MobileSubstrate/DynamicLibraries/MusicDrop.plist` targets `com.apple.Music`.

The first log line should be:

```text
MusicDrop loaded in pid ...
```

### Imports fail

Check:

- Music stayed in the foreground.
- The file is a supported DRM-free format.
- The device has free storage.
- The log contains `StoreServices available: yes`, `Server: listening on 127.0.0.1:...`, and `Enqueued ...`.

Private StoreServices APIs are undocumented and can change between iOS versions. The log is the first place to look.

### URL downloads fail

Check:

- The URL is HTTPS and public.
- The server returns audio/video, not HTML.
- The response has a supported extension or MIME type.
- The file is not empty and is under 500 MB.
- For YouTube, FFmpeg is installed and the log shows `YouTube: installed yt-dlp ...` on the first run.
- For lyrics, FFmpeg is installed and the log shows `Lyrics: embedded ...`. A failed lookup is logged and does not affect the import.

iOS may prevent `yt-dlp` from being spawned from inside Music. If that happens, download the file into Files by another method and use **Import Files**.

### The repository does not load in Sileo

Check:

- `https://<owner>.github.io/<repo>/Packages` serves plain text.
- `https://<owner>.github.io/<repo>/Release` contains hashes.
- Pages source is set to GitHub Actions.
- The deployment step succeeded.
- The source was refreshed in Sileo after deployment.

## Build locally

iOS compilation is supported on macOS or Linux with Theos. Windows users should use GitHub Actions.

```sh
export THEOS="$HOME/theos"
export THEOS_PACKAGE_SCHEME=rootless
chmod +x layout/DEBIAN/postinst layout/DEBIAN/postrm
make clean package FINALPACKAGE=1
```

The `.deb` is written to `packages/`.

To generate the repository locally:

```sh
python3 scripts/make_repo.py \
  --debs packages \
  --out docs \
  --clean \
  --homepage "https://example.github.io/A2M/"
```

Preview it with:

```sh
python3 -m http.server -d docs 8080
```

The preview's Sileo URL points at localhost and is only useful for checking the page.

## Updating

1. Edit the source.
2. Bump `Version:` in `control`.
3. Commit and push.

The workflow rebuilds the package, replaces the `.deb` in `docs/debs/`, regenerates the indexes, and deploys the repository. Users update through Sileo.

Remove `--clean` from the workflow if older versions should remain available.

## Repository layout

```text
Makefile                     Theos tweak build
control                      package metadata
MusicDrop.plist              MobileSubstrate filter for com.apple.Music
MusicDrop.xm                 tweak constructor
MDImportButton.h/.m          button, menus, picker, batch/download/lyrics UI
MDUI.h/.m                    custom bottom sheets, inputs, progress, results
MDPreferences.h/.m           persisted settings
MDDownloadManager.h/.m       URL validation, direct/YouTube/Spotify downloads
MDHelperClient.h/.m          tweak-side client for the helper daemon
MDLibraryScanner.h/.m        scans library folders and reads file tags
MDHelperProtocol.h           shared request keys and port
musicdropd.m                 rootless LaunchDaemon (yt-dlp / FFmpeg runner)
MDLyrics.h/.m                LRCLIB lookup, embedding, sidecar storage
MDLyricsPatcher.m            hooks MPNowPlayingContentItem to expose lyrics to Music
MDImporter.h/.m              file copy, metadata, artwork, lyrics, import
MDServer.h/.m                loopback HTTP file server
MDLog.h/.m                   file and console logging
layout/DEBIAN/               package scripts
layout/Library/LaunchDaemons/ helper daemon plist
scripts/make_repo.py         .deb repository index generator
scripts/make_icon.py         repository icon generator
docs/                        GitHub Pages site and generated index
.github/workflows/build.yml  build, index, commit, deploy
```

## Limitations

- Rootless only; package architecture is `iphoneos-arm64`.
- iOS 15/16 are the tested targets.
- A future iOS version can break the StoreServices classes.
- Imports depend on Music's private download queue.
- The loopback server is unauthenticated but bound to `127.0.0.1`.
- Downloads are capped at 500 MB.
- YouTube support depends on external tools and upstream site behavior.
- Lyrics depend on FFmpeg, network access to LRCLIB, and LRCLIB having a matching entry. Music decides how to render embedded lyrics; some iOS versions or file types may not show them.
- YouTube and lyrics require the helper daemon to be running. If it is blocked, MusicDrop reports that the helper is not running.
- Spotify full-track downloads are not supported.
- This is a jailbreak tweak. Keep backups of anything important.

## License

MIT. See [LICENSE](LICENSE).

MusicDrop is not affiliated with Apple. Apple and Music are trademarks of Apple Inc.
