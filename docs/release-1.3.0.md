# Luti 1.3.0

- Adds **Cloudflare Tunnel** support with an independent OAuth-protected listener for a named HTTPS domain and local approval on this Mac. OpenAI Secure MCP Tunnel and Cloudflare Tunnel have independent enable switches and can run side by side.
- Restores **Project Memory** with the `memory` MCP tool (`index`, `read`, `write`, `delete`) and local inspection UI for `MEMORY.md` indexes and topic decision files.
- Refines connection configuration with independent tunnel switches, collapsible setup guides, concurrent status updates, and automatic re-download of corrupted cached `cloudflared` binaries.
- Stops automatic reconnection retries when tunnel archive or binary hash/signature verification fails, and resets OpenAI reconnect backoff after saving new settings.
- Isolates OAuth `/oauth/token` and `/oauth/revoke` rate limits from registration and authorization, replaces undecided authorization requests from the same client, and accepts OAuth clients without optional display names.

## Upgrading

Projects, OpenAI Tunnel settings, API keys, activity, and permissions saved in 1.1 or 1.2 are retained. When upgrading from 1.2.0, existing OpenAI Tunnel configurations remain enabled automatically.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.

