# Security Policy

Luti works with approved project files, runs local processes, and can interact with browsers and macOS. If you find a security issue, report it privately so it can be investigated before the details become public.

## Supported Versions

Security fixes target the latest published release. Builds from `main` are development snapshots rather than supported releases, but you may still report issues that affect the current code.

## Reporting a Vulnerability

Send reports to **hello@aouos.com** with the subject `[Luti Security]`.

Include only what is needed to reproduce and assess the issue:

- Affected Luti version or commit
- macOS version and hardware architecture
- Security impact and affected trust boundary
- Minimal reproduction steps or a proof of concept
- Known mitigations, if any

Do not send credentials, tokens, private source code, or other sensitive project data by email. If the report requires sensitive test material, ask for a secure transfer method first.

You should receive an acknowledgment within three business days and an initial assessment within seven business days. Fix times vary with severity and complexity. Please wait for a coordinated fix and release before publishing details.

## Scope

Security issues in scope include:

- Access outside an approved project boundary
- Failures or bypasses involving authorization, OAuth, tokens, or Keychain
- Bypasses of approval or permission checks
- Command execution outside the selected policy
- Secret leakage through logs, memory, sessions, activity, or artifacts
- Execution of unverified downloaded or bundled code
- Update-signing or release-integrity failures

Use GitHub Issues for general support and feature requests. Report third-party vulnerabilities to the relevant upstream project unless they have a specific impact on Luti.

## Safe Harbor

We welcome good-faith research that avoids privacy violations, service disruption, data destruction, and unauthorized access. Test only with data and accounts you own or are authorized to use. Stop if you encounter data or credentials you are not authorized to access.
