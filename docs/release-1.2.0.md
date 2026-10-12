# Luti 1.2.0

- Removes one-time migration and cleanup of 1.0.x settings, credentials and retired storage. Startup reads the current data format directly.
- Prevents Luti-owned Chrome sessions from triggering unnecessary App Management prompts. Development builds now use a separate app identity and data directory.
- Clarifies activity results: ordinary browser actions no longer appear to be waiting for verification, and stopped jobs retain a clear stopped state.
- Fixes Python virtual environment execution and test discovery, bounded regular expression searches, and patch handling for file aliases and missing final newlines.
- Improves browser dialogs, action timeouts, credential redaction in structured results, and language-server symbol results.
- Restores saved connections after temporary Keychain failures and clarifies command permissions before starting.

## Upgrading

Projects, Tunnel settings, API keys and activity already stored in the 1.1 format are retained. If upgrading directly from 1.0.x, or if an earlier migration did not finish, select your project folder and save the Tunnel ID and API key again. Project files are unaffected. Retired app data is ignored rather than migrated or deleted.

macOS 14 or later on Apple Silicon. Browser automation requires Google Chrome.
