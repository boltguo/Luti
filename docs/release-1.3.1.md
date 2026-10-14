# Luti 1.3.1

- Cloudflare authorizations are bound to the domain instead of the selected project. Approved apps persist across project changes; 1.3.0 authorization records are migrated automatically.
- Pending Cloudflare authorization requests open as a modal approval sheet and bring Luti to the front.
- `cloudflared` uses its default protocol selection again (QUIC with automatic HTTP/2 fallback).
- OAuth accepts authorization and token requests that omit `resource` or use the bare origin. Unauthorized MCP responses include a diagnostic `error_description` without revealing active grants.
- `browser_observe` screenshots accept `maxDimension` (320–2048, default 1600) for the preview, and screenshot Artifacts use timestamped names.
- Settings links to the website and GitHub repository.

## Upgrading

Projects, Tunnel settings, API keys, activity, and permissions saved in 1.1, 1.2 or 1.3 are retained. Cloudflare apps approved in 1.3.0 stay approved.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
