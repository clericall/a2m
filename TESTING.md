# Testing MusicDrop on an iPhone X

This is the on-device test plan for the first build. It assumes:

- iPhone X on iOS 15.x or 16.x with palera1n **rootless**.
- Sileo installed and working.
- The GitHub Actions build has published the repo.
- A way to read files on the device (Filza or SSH). NewTerm is optional but useful for `curl`.

Record the iOS version, jailbreak version, and package version with every result.

## 1. Install and injection

1. Add the Pages repo URL in Sileo.
2. Install MusicDrop. Confirm the package architecture is `iphoneos-arm64`.
3. Let the post-install script finish. It should create `/var/mobile/Media/MusicDrop/` and relaunch Music.
4. Open Music and wait two seconds.

Expected:

- A pink circular button with a music note appears near the bottom-right, above the tab bar.
- The button can be dragged; it stays within the safe area and remembers its position after force-quitting and reopening Music.
- The log exists and starts with `MusicDrop loaded in pid ...`.

Check the log:

```sh
tail -n 40 /var/mobile/Media/MusicDrop/musicdrop.log
```

Expected line at launch:

```
MusicDrop loaded in pid ...
```

The `Server: listening on 127.0.0.1:<port>` line appears later, when the
first import starts the on-device file server. It will not be in the log
immediately after Music opens.

If the button is missing, verify the tweak is injected before debugging import:

```sh
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/MusicDrop.dylib
ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/MusicDrop.plist
```

Also confirm MobileSubstrate/ElleKit is working for another tweak. A missing button is an injection problem, not an import problem.

## 2. Basic MP3 import

Prepare a DRM-free MP3 with ID3 tags and embedded cover art. Copy it into the MusicDrop inbox or keep it in Files.

1. Tap the floating button.
2. Pick the MP3.
3. Wait for the "Preparing import…" / "Importing 1 of 1…" overlay to finish.
4. Keep Music open for at least a minute.

Expected:

- An alert says the track was queued.
- The log shows an enqueued item with its local URL.
- The song appears in **Recently Added** and **Songs**.
- Title, artist, album, duration, and artwork match the file.
- Playback works and the lock-screen controls show the tags.

If the alert says it was queued but no song appears:

- Keep Music open longer.
- Check the log for server requests (`GET /media/...`).
- Check free space.
- Try an M4A next to separate file parsing from StoreServices behavior.

## 3. M4A / AAC / ALAC

Repeat the single-file test with:

- AAC in `.m4a`.
- ALAC in `.m4a` if available.
- A file with no artwork.
- A file with a very large cover (for example 3000×3000).

Expected:

- AAC/ALAC decode and import.
- Missing artwork gets the generated pink MusicDrop cover.
- Large artwork is resized and does not make the import fail.

## 4. Multiple files

Select at least five files in one picker session, including a mix of MP3 and M4A.

Expected:

- Progress counts up through each file.
- Every successful file is imported.
- Failures are listed individually in the final alert, and successful files are still imported.
- The log shows one `Enqueued` line per successful file.

Test a batch with one deliberately broken file (empty `.mp3` or an OGG renamed to `.mp3`). The broken file should fail without stopping the rest.

## 5. Filenames and metadata fallbacks

Test:

- A file named `Artist - Title.mp3` with no tags.
- A filename with spaces, emoji, or non-Latin characters.
- A file with tags but no title.
- A file with a title but no artist.

Expected:

- `Artist - Title.mp3` is split into artist and title.
- Unicode filenames copy and import without corruption.
- Missing fields fall back to `Unknown Artist`, `Unknown Album`, or the filename.
- No crash on odd metadata.

## 6. Unsupported formats

Try an OGG, Opus, or WMA file.

Expected:

- The picker may show the file because it is audio, but the import rejects it with a clear message.
- The log records the unsupported extension.
- No song is added.

## 7. Background behavior

1. Start an import with a larger file.
2. Immediately swipe to the Home screen.
3. Wait 30 seconds, then return to Music.

Expected:

- MusicDrop requests background time, but iOS may suspend Music anyway.
- If the import completes, the song appears.
- If it fails, the log shows the server connection ending early or the store request never arriving.
- This is a known limitation; the UI tells the user to keep Music open.

## 8. Relaunch and reboot

1. Force-quit Music and reopen it. The button should return.
2. Reboot the phone, re-jailbreak, and open Music. The button should return.
3. Confirm the button position is remembered.

If the tweak disappears after a reboot, verify the jailbreak's tweak injection is active before reinstalling.

## 9. Uninstall

1. Remove MusicDrop in Sileo.
2. Open Music and confirm the button is gone.
3. Confirm songs already imported still play.
4. Confirm `/var/mobile/Media/MusicDrop/` still exists (user data is intentionally kept).

Delete that folder manually with Filza if you want to reclaim the space.

## URL downloads

1. Tap the floating button, choose **Download URL**, and enter a small direct HTTPS URL to an MP3 or M4A you are authorized to save.
2. Wait for the download and the normal import to finish.
3. Repeat with a YouTube video URL you own, first with `yt-dlp` and FFmpeg installed, then with one of them removed.
4. Repeat with a Spotify track URL.

Expected:

- Direct downloads save a supported file under `/var/mobile/Media/MusicDrop/downloads/` and then import like a local file.
- YouTube downloads show progress, produce M4A with metadata/artwork, and import.
- Missing `yt-dlp` or FFmpeg produces an actionable error without crashing Music.
- The log shows `Helper: listening on 127.0.0.1:45454`. If instead the app says the helper is not running, check that the LaunchDaemon loaded: `launchctl print system/com.musiccc.musicdropd`.
- Spotify URLs explain that full-track audio is DRM-protected and unavailable.
- Invalid, `http://`, private-network, HTML, empty, and oversized responses fail before importing.
- The button returns to its normal enabled state after every success and failure.

## Batch download, Spotify links, Fix Lyrics

1. Open **Batch Download**, paste three YouTube URLs (one per line) and submit. Confirm progress counts 1/3 → 3/3 and all three songs import.
2. Open **Download URL** with a Spotify track link. The log should show `Helper: YouTube request for ...` after `Resolving Spotify link…`, and a matching song should import.
3. Open **Fix Lyrics → Scan Music Library**. Confirm the progress card shows `Adding lyrics N of M…` and the result reports the number embedded/skipped. Restart Music and check the Now Playing lyrics view.
4. Open **Fix Lyrics → Choose Files**, pick an audio file, and confirm the result.
5. Open **Settings → Clear Cached Data** and confirm `/var/mobile/Media/MusicDrop/bin/yt-dlp` is removed, then that the next download re-fetches it.

## Lyrics

1. With FFmpeg installed, import or download a well-known song (for example Queen — Bohemian Rhapsody).
2. Open the song, start playback, and open the Now Playing lyrics view.
3. Repeat with a song LRCLIB does not have, and with FFmpeg temporarily unavailable.
4. Repeat with an MP3 and an M4A so both tag formats are covered.

Expected:

- The log shows `Lyrics: embedded ...` and the song shows time-synced lyrics in Music.
- Plain lyrics are used when synced lyrics are unavailable.
- Missing matches or missing FFmpeg do not block the import and are logged.
- Title, artist, artwork, and playback are unchanged by embedding.

## 10. Log and server diagnostics

The log is at:

```
/var/mobile/Media/MusicDrop/musicdrop.log
```

It rotates to `musicdrop.log.old` when it exceeds 1 MB.

The server starts on the first import. To test it from the device, start an
import, find the `Server: listening on 127.0.0.1:<port>` line in the log, and
use NewTerm or SSH while Music is still open:

```sh
curl -i http://127.0.0.1:<port>/
```

Expected: `200 OK` and `MusicDrop server is running.`

Media URLs are random and only valid for files registered during an import. A URL from an old log may return 404 after the file is pruned or after Music relaunches.

Useful system log filter while importing:

```sh
log stream --predicate 'process == "Music"' --style compact
```

For store-daemon errors, also check:

```sh
log stream --predicate 'process == "itunesstored" OR process == "storedownloadd"' --style compact
```

## Pass criteria for a first release

- Injection works on a clean reboot.
- At least one MP3 and one M4A import with correct tags and artwork.
- Multiple selection works.
- Unsupported files fail cleanly without blocking the batch.
- The floating button does not interfere with normal Music navigation.
- The repo installs and updates through Sileo.
- The log contains enough detail to diagnose a failed import without a debugger.

## Reporting a problem

Include:

- iPhone model and iOS version.
- Jailbreak and version (palera1n rootless, etc.).
- MusicDrop version from Sileo.
- The last 40 lines of `musicdrop.log`.
- File format, extension, and whether it has artwork.
- Whether Music stayed in the foreground.
- A screenshot of the alert, if there is one.
