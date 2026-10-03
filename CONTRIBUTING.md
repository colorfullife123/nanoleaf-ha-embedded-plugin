# Contributing

Thanks for helping improve the project.

## Before opening an Issue

1. Confirm the problem occurs on the latest Release.
2. Run `C:\ProgramData\NHA\status.ps1`.
3. Remove tokens, IP addresses, Windows usernames and device serial numbers from all output.
4. State the exact Nanoleaf Desktop, plugin, Windows and Home Assistant versions.

Never upload Nanoleaf Desktop binaries, `app.asar`, official source bundles, runtime configuration, logs containing personal data or backup archives.

## Pull requests

1. Fork the repository and create a focused branch.
2. Keep third-party proprietary files out of the repository.
3. Run `npm test`.
4. On Windows, verify every PowerShell file parses successfully.
5. Explain user-visible behavior, compatibility impact and rollback steps in the pull request.

Changes to ASAR markers must be exact, length-preserving and covered by a synthetic-archive round-trip test. Do not add fuzzy matching against unknown Nanoleaf versions.
