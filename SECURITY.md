# Security policy

## Supported version

Only the latest GitHub Release is supported. The current tested release is 1.1.4.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting feature when it is available for this repository. Do not open a public Issue for an unpatched security problem.

Include the plugin version, Nanoleaf Desktop version, Windows version, reproduction steps and the smallest possible diagnostic excerpt. Remove all Bearer tokens, IP addresses, Windows usernames and device serial numbers before sending material.

## Security model

- The bridge requires a randomly generated 256-bit Bearer token.
- The Windows firewall rule limits inbound TCP access to the HAOS IPv4 supplied at installation.
- The service is intended for a trusted private LAN and does not provide TLS. Do not expose port 17654 to the public internet.
- Runtime secrets and device identifiers live in `C:\ProgramData\NHA\config.json`; they are not part of the release archive.
- The installer patches a locally installed `app.asar` and keeps a verified official backup. It refuses archives whose exact compatibility markers are unknown.

This is an unofficial community project and is not affiliated with Nanoleaf.
