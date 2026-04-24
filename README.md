# Peridio Daemon

`peridiod` is a reference implementation of a Peridio Agent for Embedded Linux.

Peridio offers several ways to integrate peridiod into your build workflow via the following integration paths:

* Build system integration with [Yocto](build-tools/yocto) or [Buildroot](build-tools/buildroot)
* Leverage one of our pre compiled artifacts from the [Github releases page](https://github.com/peridio/peridiod/releases)
* Running in a container leveraging one of our [official container images](https://hub.docker.com/r/peridio/peridiod).
* Cross-Compiling as part of your custom build tools.
* As part of an existing [Elixir based application](https://github.com/peridio/peridio-nerves-example).

See the [Peridio Daemon Docs](https://docs.peridio.com/peridio-core/tools/peridio-daemon/overview) for more information

## Filesystem permissions

peridiod stores cached firmware binaries, encryption key material, HMAC signatures, and log files under `cache_dir`. This directory and its `log/` subdirectory must be restricted to the daemon user to prevent exposure of sensitive data to other local users.

| Path | Required mode | Required owner |
|---|---|---|
| `cache_dir` (default `/var/lib/peridiod`) | `0700` | daemon user (root by default) |
| `{cache_dir}/log` | `0700` | daemon user (root by default) |

Packaged installs (deb/rpm) set `cache_dir` to `/var/peridiod` and create it at `0700` automatically.

If peridiod detects a drift from these requirements at startup it logs a warning and attempts to correct the mode, but continues running. If ownership does not match the daemon user, a warning is logged.
