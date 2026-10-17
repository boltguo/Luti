# Luti 1.4.0

- Restores **Safe Mode**, now the default for every project. Commands such as `rm`, `mv` and `chmod`, Git commands that change repository state, `run_shell`, inline interpreter code and path deletion wait for a one-time approval on this Mac. The Full Access switch on the project page turns approval off and applies immediately, even while the runtime is running.
- Splits project memory into `memory_query` (`index`, `read`, read-only) and `memory_action` (`write`, `delete`). Reading memory no longer needs confirmation in AI clients.
- Memory writes never overwrite blindly: replacing or deleting a file requires the `sha256` the client last read, so concurrent clients cannot lose each other's updates. Replacements keep omitted name, description and kind.
- Hand-off between AI clients: before multi-step work an AI writes a `kind=task` memory file with a checklist. `project_info` shows each task's progress and author plus the latest changes made by any client, so another session can continue even when the previous one stopped mid-task.
- `runtime_status` reports the permission mode.
- Tools are consolidated from 26 to 24: `browser_inspect` actions move into `browser_observe`, and `browser_dialog` actions (`accept`, `dismiss`) move into `browser_action`. Read-only tools no longer take `projectToken`.
- `git_query`, `path_action`, `edit_files` and `code_query` no longer advertise defaults that belong to other actions, which could make calls fail.
- `run_process` applies the same command checks as `run_shell` when it launches a shell with `-c`.

## Upgrading

**Refresh Luti's tool list in each connected AI client**, or remove and re-add the connector. `memory`, `browser_inspect` and `browser_dialog` are replaced; calls to them fail until the client reloads the tool list. The home page shows this reminder whenever the tool list changes, until you close it.

Existing projects open in Safe Mode. Turn on Full Access on the project page to keep the previous behavior.

Projects, Tunnel settings, API keys, activity, permissions and project memory saved in 1.1, 1.2 or 1.3 are retained.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
