spotDL Local Web UI

How to start:
1. Double-click `start-web.cmd`
2. Open `http://localhost:8976` in your browser

What it does:
- paste a Spotify playlist URL
- creates a separate folder for that playlist under `downloads`
- saves playlist metadata first
- downloads the playlist with spotDL
- retries missing tracks one-by-one with broader fallback providers

Notes:
- keep this whole folder together so `.tools` and `.spotdl` stay available
- the app runs locally on your PC and saves files into this folder
- if a song still fails after retries, it will show up in the Missing songs list
