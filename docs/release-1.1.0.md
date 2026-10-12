# Luti 1.1.0

- Connects only through OpenAI Secure MCP Tunnel; Cloudflare, ngrok, OAuth, project memory, sessions and checkpoints are removed.
- Works on one selected project folder.
- On first launch, migrates the active project, Tunnel ID and runtime API key from 1.0.x and removes data this version no longer uses.
- Shows the tunnel's real control-plane state, including the reason while it reconnects, and uses the macOS HTTPS proxy.
- Improves stability for job input, browser sessions, downloads, Quit and activity history.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
