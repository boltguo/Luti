# Luti 1.5.0

- Adds Self-hosted VPS connections alongside OpenAI and Cloudflare. Luti generates a dedicated SSH identity and a server setup script; the Mac connects through an encrypted reverse SSH tunnel, with OAuth approval remaining on the Mac. Multiple connections can run together.
- Adds `project_select` to switch the shared workspace between locally approved projects while the runtime is idle. Active jobs, tool calls and pending approvals prevent a switch. Each project retains its permissions, memory and activity; stale project tokens cannot mutate the newly selected project.
- Simplifies connection settings and project navigation with a consistent Material 3 Expressive interface. VPS SSH fields stay visible; only the deployment guide is collapsed. Cloudflare can fall back to HTTP/2 when its initial connection fails.
- Unconfigured connection switches open setup while staying off; saving valid settings turns them on. Previously enabled switches without configuration are reset to off.
- Fixes Safe Mode approval for attached interpreter flags, Node `--eval=…` and `--print`, and discovered project scripts using Git global options such as `-C` and `-c`. Ordinary project build-output cleanup remains available.
- Adds expandable approval details with the complete redacted command arguments, working directory, standard input, project script and supplied environment.
- Keeps real changes in cross-client hand-off summaries when later calls only perform dry runs. An open project's activity page reloads its history when another project becomes active.
- Fixes SSH control sockets under long home-directory paths. Saving VPS settings preserves pinned server keys; an unexpected host-key change continues to block the connection.
- Improves VPS deployment: an already active UFW gets TCP 80/443 rules, the guide distinguishes cloud firewall rules and certificate issuance, and remains readable while running. Cloudflare instructions display the current build’s local service port.

## Upgrading

**Refresh Luti's tool list in each connected AI client**, or remove and re-add the connector. There are now 25 tools, including `project_select`. After a project switch, clients must read the new project token before making changes.

Existing projects, permission choices, memory, activity and connection settings are retained. VPS setup is optional. HTTPS and SSH encrypt the network links; the VPS reverse proxy can read traffic where HTTPS terminates, as can Cloudflare when its proxy is enabled. See [VPS setup and security](https://github.com/boltguo/Luti/blob/v1.5.0/docs/vps.md).

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
