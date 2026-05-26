# Spotify Playlist Downloader

This project gives you a simple local web app for downloading Spotify playlists, albums, and tracks on your own PC.

It uses [spotDL](https://github.com/spotDL/spotify-downloader) for the actual Spotify metadata and download workflow, then saves finished files into local folders inside this repo.

## What it supports

- Playlist links
- Album links
- Track links
- Bulk downloads

Artist URLs are currently not available.

## How to use it

1. Clone or pull this repo to your PC.
2. Run `start-web.cmd`.
3. If some local runtime files are missing, the app will ask before downloading them.
4. Wait for the local web address to appear in the startup window.
5. Open that local URL in your browser.
6. Paste your Spotify playlist, album, or track link and start the download.

## What happens on first run

On the first run, the app checks whether the local runtime is ready.

If something is missing, it can download what it needs step by step:

- `spotDL`  
  Needed to read Spotify metadata and manage the download process.

- `FFmpeg`  
  Needed to convert and finalize audio files.

- `Deno`  
  Needed to run the local web app.

- `spotDL config`  
  Needed for the local downloader setup and default provider settings.

If everything is already installed, later launches stay quiet and go straight to the local web UI.

## Where files go

Everything stays local to this repo.

- Downloaded music goes into `downloads/`
- Runtime files are kept in `.tools/` and `.spotdl/`
- Job history and logs are kept in `app-data/`

These folders are meant to stay on your machine and are not intended to be committed back into Git.

## Notes

- Audio is not downloaded from Spotify directly.
- spotDL reads Spotify metadata, then matches audio from supported providers.
- If a song still cannot be downloaded after retries, it will show up in the app as missing with a log entry explaining what happened.
