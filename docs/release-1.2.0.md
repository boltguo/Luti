# Luti 1.2.0

- Removes one-time migration and cleanup of 1.0.x settings, credentials and retired storage. Startup reads the current data format directly.
- Prevents Luti-owned Chrome sessions from triggering unnecessary App Management prompts. Development builds now use a separate app identity and data directory.
- Clarifies activity results: ordinary browser actions no longer appear to be waiting for verification, and stopped jobs retain a clear stopped state.
- Fixes Python virtual environment execution and test discovery, bounded regular expression searches, and patch handling for file aliases and missing final newlines.
- Improves browser dialogs, action timeouts, credential redaction in structured results, and language-server symbol results.
- Restores saved connections after temporary Keychain failures and clarifies command permissions before starting.
- Preserves credential-redaction context when process logs are compacted, including retained-tail log pages.
- Prevents older successful-poll metrics from clearing newer Tunnel errors. Connection recovery remains automatic; changing configuration while connected requires stopping the Runtime and ends active jobs and browser sessions.

## Upgrading

Projects, Tunnel settings, API keys and activity already stored in the 1.1 format are retained. If upgrading directly from 1.0.x, or if an earlier migration did not finish, select your project folder and save the Tunnel ID and API key again. Project files are unaffected. Retired app data is ignored rather than migrated or deleted.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.

## Known limitation

Some absolute executable paths, including Homebrew symlinks and commands beginning with an absolute path in `run_shell`, can be rejected by project-scope checks. Use the executable name from the developer PATH (for example, `node` or `true`) where applicable. This existing compatibility issue is deferred; project-scope checks remain enforced.
