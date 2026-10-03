# Changelog

## 1.1.4 — 2026-10-03

- Published a generic installer with automatic Pegboard USB and Windows IPv4 discovery.
- Moved device IDs, names and network addresses from source code into local runtime configuration.
- Added dynamic one- or two-device rendering in the embedded HA window.
- Preserved the `/device/j`, `/device/k` and `/device/all` compatibility endpoints.
- Added repository privacy checks and a synthetic ASAR patch round-trip test.
- Retained compatibility with both array-based and legacy final-cleanup callbacks.

## 1.1.3

- Ran colour-calibration and LTPDU client-manager cleanup before main-process self-termination.
- Fixed residual Nanoleaf processes after all other cleanup had completed.

## 1.1.0–1.1.2

- Replaced external forced-exit tasks with bounded cleanup inside the Nanoleaf main process.
- Added bridge shutdown and renderer cleanup ordering.

## 1.0.0–1.0.6

- Added the embedded Home Assistant bridge, UI, update preparation and repair workflow.
- Iterated on legacy exit cleanup before the internal cleanup design was completed.
