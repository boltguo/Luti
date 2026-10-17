# Luti 1.4.0

- Restores **Safe Mode**, now the default for every project. Commands such as `rm`, `mv` and `chmod`, Git commands that change repository state, `run_shell`, inline interpreter code and path deletion wait for a one-time approval on this Mac. The Full Access switch on the project page turns approval off and applies immediately, even while the runtime is running.
- Splits project memory into `memory_query` (`index`, `read`, read-only) and `memory_action` (`write`, `delete`). Reading memory no longer needs confirmation in AI clients.
- Memory writes never overwrite blindly: replacing or deleting a file requires the `sha256` the client last read, so concurrent clients cannot lose each other's updates. Replacements keep omitted name, description and kind.
- `project_info` lists the project's memory files, and `runtime_status` reports the permission mode.

## Upgrading

**Refresh Luti's tool list in each connected AI client**, or remove and re-add the connector. The `memory` tool is replaced by `memory_query` and `memory_action`; calls to `memory` fail until the client reloads the tool list.

Existing projects open in Safe Mode. Turn on Full Access on the project page to keep the previous behavior.

Projects, Tunnel settings, API keys, activity, permissions and project memory saved in 1.1, 1.2 or 1.3 are retained.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
