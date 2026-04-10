# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`peridiod` is an Elixir-based reference implementation of a Peridio Agent for Embedded Linux. It's a device management daemon handling firmware/bundle updates, binary installation, and remote access tunnels for embedded systems.

## Commands

```bash
# Install deps and compile
make compile
# or: mix deps.get && mix compile

# Run tests
mix test

# Run a single test file
mix test test/peridiod/plan_test.exs

# Run a single test by line number
mix test test/peridiod/plan_test.exs:42

# Build a release binary
make release
# or: mix release --overwrite

# Format code
mix format
```

## Architecture

### Supervision Tree

```
Peridiod.Application
└── Supervisor (one_for_one)
    ├── Cache               - File cache with Ed25519/SHA256 signing
    ├── Cloud.Supervisor
    │   ├── Cloud.Socket    - WebSocket to Peridio cloud (via Slipstream)
    │   ├── Cloud.Update    - Polls for available updates
    │   ├── Cloud.Tunnel    - Remote access tunnel (RAT) management
    │   └── Cloud.NetworkMonitor - Watches network interface changes
    ├── Bundle.Server       - Orchestrates bundle installation
    ├── Binary.Installer.Supervisor
    ├── Binary.Downloader.Supervisor
    ├── Plan.Server         - Executes installation plans phase by phase
    └── Plan.Step.Supervisor
```

### Update Flow

1. `Cloud.Socket` receives update notification from Peridio cloud over WebSocket
2. `Bundle.Server` receives the bundle/distribution, filters already-installed binaries
3. `Plan` module builds an installation plan with four phases:
   - **on_init**: Cache metadata, mark system state as in-progress
   - **run**: Parallel/sequential steps — download, install binaries, enable Avocado extensions
   - **on_finish**: Stamp installed, advance system state, reboot if required
   - **on_error**: Reset progress state
4. `Plan.Server` executes the plan step by step, dispatching to `Plan.Step.Supervisor`

### Key Modules

| Module | Purpose |
|--------|---------|
| `Peridiod.Config` | Reads `peridio-config.json` (or `$PERIDIO_CONFIG_FILE`). Supports `file`, `pkcs11`, `uboot-env`, `env` key pair sources |
| `Peridiod.Cache` | Content-addressed file store; signs/verifies every file with Ed25519 |
| `Peridiod.Plan` | Pure function — given a `Bundle`, returns a `%Plan{}` with ordered step lists |
| `Peridiod.Plan.Server` | GenServer that drives plan execution through phases |
| `Peridiod.Bundle.Server` | GenServer managing the overall bundle install lifecycle |
| `Peridiod.Binary.Installer` | Dispatcher; selects installer module (`fwup`, `avocado-os`, `avocado-ext`, `deb`) based on `custom_metadata["peridiod"]["installer"]` |
| `Peridiod.Cloud` | Manages Peridio SDK client, TLS, and DNS caching |
| `Peridiod.Distribution` | Represents an update payload from cloud (legacy path via distributions) |

### Installer Types

Binary installers are selected via `custom_metadata["peridiod"]["installer"]`:
- `fwup` — streams firmware to a block device via fwup
- `avocado-os` — Avocado OS image install
- `avocado-ext` — Avocado extension; requires a subsequent `AvocadoExtensionEnable` step
- `deb` — Debian package

Avocado components have special ordering in `Plan`: extensions install first → enable step → OS install (or refresh if no OS update).

### Configuration

Config is loaded from `peridio-config.json` (default: `$XDG_CONFIG_HOME/peridio/peridio-config.json` or `~/.config/peridio/peridio-config.json`). Override with `$PERIDIO_CONFIG_FILE`.

Key config fields: `device_api.url`, `fwup.devpath`, `fwup.public_keys`, `node.key_pair_source`, `trusted_signing_keys`, `targets`, `remote_access_tunnels`.

### External Dependencies (GitHub-pinned)

- `peridio_sdk` (peridio/peridio-elixir) — Device API client
- `peridiod_persistence` (peridio/peridiod-persistence) — KV store abstraction (in-memory for tests, file-backed in prod)
- `peridio_rat` (peridio/peridio-rat) — WireGuard-based remote access tunnels
- `peridio_net_mon` (peridio/peridio-net-mon) — Network interface monitoring

### Test Setup

Tests use `--no-start` (configured in `mix.exs` aliases). Key test config (`config/test.exs`):
- Socket disabled
- In-memory KV backend (`PeridiodPersistence.KVBackend.InMemory`)
- Test workspace at `test/workspace/cache`
- Test support files in `test/support/`
