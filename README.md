# Spotify Playlist Downloader

Local web UI for downloading Spotify playlists with `spotdl`.

## What this repo contains

- a local browser UI where you paste a Spotify playlist URL
- a local worker that runs `spotdl`
- automatic per-playlist output folders under `downloads`
- a one-click repair/setup flow that downloads required runtime assets

## What this repo does not commit

Large runtime and download folders stay local:

- `.tools/`
- `.spotdl/`
- `.deno/`
- `downloads/`
- `app-data/`

Those are recreated automatically by the repair/setup scripts.

## One-click start

1. Double-click `start-web.cmd`
2. Wait for runtime repair/setup to finish
3. Open `http://localhost:8976`
4. Paste a Spotify playlist URL

`start-web.cmd` automatically:

- checks/downloads the latest Windows `spotdl.exe`
- ensures local `ffmpeg.exe`
- ensures local `deno.exe`
- starts the local web app

## Manual repair

If you want to refresh dependencies before starting the app, run:

- `repair.cmd`

To force re-download the runtime assets:

- `repair.cmd -ForceRefresh`

## Notes

- Audio is not downloaded from Spotify directly.
- `spotdl` reads Spotify metadata, then finds audio from providers such as YouTube Music, YouTube, and fallback sources.
- If a song still fails after retries, it appears in the UI's missing songs section and full log.
