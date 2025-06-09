# peridiod releases

## v3.1.4-rc.1

* Bug fixes
  * [Core] Fixed file installer cleanup of old files
  * [Core] Fixed failure of install completion to stamp cached file
  * [Ubuntu] Fixed default locations for certificate key paths

## v3.1.3

* Bug fixes
  * [Core] Fixed persisted state can become corrupted when performing `get_and_update`

## v3.1.2

* Bug fixes
  * [Ubuntu | Red Hat] Updated peridiod deb / rpm packages to include additional dependency recommends for remote access tunnels.
  * [Ubuntu | Red Hat] When installing Peridiod for the first time from deb / rpm package default peridio_vsn_current to 0.1.0. If you would like installs provisioned with this version to adopt into the release graph, configure your first build in the graph with a version requirement of `~> 0.1` or similar

## v3.1.1

* Bug fixes
  * [Network Monitor] Updated internet host list to monitor peridio infrastructure over 443 to closely represent "healthy" conditions.
    Previously, internet connectivity health was determined from checks on port 50 to common internet dns server addresses. This would yield false results.

## v3.1.0

* Enhancements
  * [Network Monitor] Added network monitoring options for devices with multi-wan connected network interfaces. Linux will route requests to the internet using the route with the lowest metric. If the default route with the lowest metric is unable to access the internet but other interfaces can, we should try to use those other interfaces. This feature enables peridiod to monitor a specified list of priority network interfaces for connectivity. It will bind network communications to a prioritized route and fail over if it no longer can connect to the internet.

  Add the following to your peridio config to enable:

  ```json
  "network_monitor": {
    ["eth0", "eth1", {"ppp0": {"disconnect_on_higher_priority": true}}]
  }
  ```

    * The list is in order of highest priority to lowest priority.
    * It can contain `string` network device names, or, an object with a single key of the interface name and options `{"ppp0": {}}`
    * Specifying the option `"disconnect_on_higher_priority": true` will forcefully disconnect from that interface when a higher priority interface becomes * available. This is helpful for preventing long lived socket connections from persisting on metered data links like cellular.
    * In the example above, if we are bound to `eth1` and `eth0` regains connectivity to the internet, we will not disconnect from eth1

  * [Change Plans] The underlying binary installer engine has been rewritten to prepare support for complex bundle installation cases such as
    * Inter-bundle binary dependencies
    * Custom lifecycle script execution
    * Better handling of sequential and parallel installers
    * Multi-stage updates that require multiple update reboots

* Bug fixes
  * Fixes issue installing multiple binaries in a bundle in parallel using installers that only support sequential execution
    * Affected installers: `swupdate`, `dpkg`, `apt`, `opkg`
  * Fixes issue where installers that can only install from path would not cache the binary before running the installer
    * Affected installers: `swupdate`, `dpkg`, `apt`, `opkg`

## v3.0.1

* Bug fixes
  * [Bundles] Fix issue with bundle update resolution where all binaries may be installed instead of only binaries that are not installed.

## v3.0.0

Added Support for Bundle Distributions

**Backwards compatible with firmware deployments**

### Added `peridiod` config keys introduced:

* `update_poll_enabled`: true | false
* `update_poll_interval`: the interval in ms to automatically check for updates
* `update_resume_max_boot_count`: Max restart / reboots before failing an resumed bundle install. Defaults to `10`
* `cache_dir`: a writable path where `peridiod` can store release metadata
* `targets`: A list of string target names for peridiod to install as part of a release update
* `trusted_signing_keys`: A list of base64 encoded ed25519 public signing key strings
* `reboot_delay`: Number of milliseconds to wait before rebooting the system Defaults to 5000.
* `reboot_cmd`: The system reboot command. Defaults `reboot`
* `reboot_opts`: Extra args to be passed to the reboot command. Defaults `[]`
* `reboot_sync_cmd`: The system sync command to force filesystem writes. Defaults `sync`
* `reboot_sync_opts`: Extra args to be passed to the sync command. Defaults `[]`
* `cache_log_enabled`: Enable writing logs to the cache_dir. Default `true`
* `cache_log_max_bytes`: Max bytes for log file storage. Default `10485760` (10mb)
* `cache_log_max_files`: Max number of rotating log files to store. Default `5`
* `cache_log_compress`: Compress logs on rotation. Default `true`
* `cache_log_level`: Default `debug` Options `debug` | `info` | `warning` | `error`

More information can be found in the [Peridiod Configuration docs](https://docs.peridio.com/integration/linux/peridiod/configuration)

### U-Boot Environment additions

peridiod releases will track and expose release metadata in the uboot environment under the following new keys.

**If you are using UBoot environment variable whitelisting features in your bootloader it is important that these values be added.**

* `peridio_via_current`: the PRN of the current installed release or bundle override
* `peridio_via_previous`: the PRN of the previous installed release or bundle override
* `peridio_via_progress`: the PRN of the release or bundle override in progress
* `peridio_vsn_current`: the semantic version of the current installed release
* `peridio_vsn_previous`: the semantic version of the previous installed release
* `peridio_vsn_progress`: the semantic version of the release in progress
* `peridio_bin_current`: an concatenated key / value paired encoded string of `<binary_id><custom_metadata_sha256_hash>` internally used to diff installed binaries from bundle to bundle
* `peridio_bin_previous`: an concatenated key / value paired encoded string of `<binary_id><custom_metadata_sha256_hash>` internally used to diff installed binaries from bundle to bundle
* `peridio_bin_progress`: an concatenated key / value paired encoded string of `<binary_id><custom_metadata_sha256_hash>` internally used to diff installed binaries from bundle to bundle
* `peridio_bun_current`: the PRN of the current installed bundle
* `peridio_bun_previous`: the PRN of the previous installed bundle
* `peridio_bun_progress`: the PRN of the bundle install in progress
* `peridio_bc_progress`: Boot / restart counter for peridiod for in progress bundle installation resumption
* `peridio_bc_current`: Reserved for future use

More information can be found in the [Peridiod Configuration docs](https://docs.peridio.com/integration/linux/peridiod/configuration)

### Installing Bundles and Binaries

Releases allow greater control and flexibility to managing devices in the field. You can package and bundle many binaries with a release enabling workflows for use in embedded products, empowering app stores, and managing connected peripheral device firmware. It offers advanced deployment options for scheduled and phased rollouts.

To use releases, binaries must be configured to use an installer. An Installer is a module that can handle the last mile of deploying your binary onto your device. The following installer modules are currently supported:

  * `fwup`: Binary in the (fwup)[https://github.com/fwup-home/fwup] format.
  * `file`: Writes individual files to a writeable location on the system.
  * `deb`: (Debian package manager)[https://www.debian.org/doc/manuals/debian-faq/pkg-basics.en.html] install format.
  * `rpm`: (RPM Package manager)[https://rpm.org/] install format.
  * `opkg`: (OPkg Package manager)[https://openwrt.org/docs/guide-user/additional-software/opkg] installer format.
  * `swupdate`: (SWUpdate)[https://sbabic.github.io/swupdate/swupdate.html] package format.


See the [Peridiod Packaging Updates integration docs](https://docs.peridio.com/integration/linux/peridiod/updates) for more information.

## v3.0.0-rc.7

* Enhancements
  * Full support for installing via bundle overrides and releases in cohort workflows
  * Improved log messaging
* Bug fixes
  * Fixed issue with Cache downloader appending to existing cache file instead of starting over on restart. This was causing the cache download file to fail signature checks and grow the cache to unreasonable size.
  * Allow custom_metadata installer_opts key to be optional. Caused Installer process to crash if omitted.

## v3.0.0-rc.6

* Bug fixes
  * Fix issues with `swupdate`, `deb`, `apt`, and `opkg` installers writing intermediate files outside peridiod cache dir.
  * Improved error handling for responses from release server check for update when a device is not in a cohort.
  * Improved error handling for erroneous responses from the release server.
  * Fixed issue with release server crashing peridiod on start if `release_poll_enabled` is enabled and the server responds abnormally.
  * Improvements to installers for verifying system executable dependencies are present.
  * Trim plain text from the preamble of certificates in ubootenv and env. This was causing `SERVER ALERT: Fatal - Handshake Failure`.
  * Remote Access Tunnels: Fix issue where CIDR and Port negotiation may fail if a tunnel is in the process of closing when the system is queried for used resources.

## v3.0.0-rc.5

* Enhancements
  * Support for migrating from v2 to v3 peridiod
  * Binary Installers
    * Added swupdate installer
    * Added opkg installer
* Bug fixes
  * Improved error handling for releases and installers. If an installer fails with an error, the installer will be stopped and the remainder of the release will be halted. The device will continue to report it is on the previous release
  * Store binary metadata in the cache with the custom_metadata_hash in its path

## v3.0.0-rc.4

* Bug fixes
  * Prevent release server from applying another release if one is in progress
  * Bump erlexec to latest to fix compilation issues on Apple Silicon

## v3.0.0-rc.3

* Bug fixes
  * Allow `nil` for release version data in device API headers

## v3.0.0-rc.2

* Enhancements
  * Added support for deb and rpm package installers

* Bug fixes
  * Fixed issues in checking for release logic for releases

## v3.0.0-rc.1

* Bug fixes
  * Update systemd peridiod.service to point to /usr/lib/peridiod
  * Allow `release_poll_interval` to be configured from PERIDIO_CONFIG_FILE

## v3.0.0-rc.0

**This is a major update and this release should be thoroughly tested.**

Add support for Peridio Cloud Releases

Peridio Releases allow you greater flexibility in how you manage the content installed on your device.

### Config

New `peridiod` config keys introduced:

* `release_poll_enabled`: true | false
* `release_poll_interval`: the interval in ms to automatically check for updates
* `cache_dir`: a writable path where `peridiod` can store release metadata
* `targets`: A list of string target names for peridiod to install as part of a release update
* `trusted_signing_keys`: A list of base64 encoded ed25519 public signing key strings

### Installers

Peridiod now has a concept of "Installers", initially supported installer types are `file` and `fwup`. When using releases, you will have to use the `custom_metadata` of a binary, artifact version, or artifact to instruct peridiod how to install the binary content. Here is an example of what custom metadata for installers would look like:

fwup

```json
{
  "installer": "fwup",
  "installer_opts": {
    "devpath": "/dev/mmcblk0",
    "extra_args": [],
    "env": {}
  },
  "reboot_required": true
}
```

file

```json
{
  "installer": "file",
  "installer_opts": {
    "name": "my_file.txt",
    "path": "/opt/my_app",
  },
  "reboot_required": false
}
```

The custom metadata will need to configured on a Binary, Artifact Version, or Artifact record. You can add this custom metadata to these records using Peridio CLI v0.22.0 or later.

### U-Boot Environment additions

peridiod releases will track and expose release metadata in the uboot environment under the following new keys

* `peridiod_rel_current`: the PRN of the current installed release
* `peridiod_rel_previous`: the PRN of the previous installed release
* `peridiod_rel_progress`: the PRN of the release in progress
* `peridiod_vsn_current`: the semantic version of the current installed release
* `peridiod_vsn_previous`: the semantic version of the previous installed release
* `peridiod_vsn_progress`: the semantic version of the release in progress
* `peridiod_bin_current`: an concatenated key / value paired encoded string of `<binary_id><custom_metadata_sha256_hash>` internally used to diff installed binaries from release to release

### Preparing a release

Peridiod will track installed binaries from release to release by updating the `peridio_bin_current` value in the u-boot-env. When burning in a device firmware for the first time, you can pre-compute this field value with information about the supplied binaries by constructing a concatenated string according to the field specifications. This will prevent peridiod from installing binaries unnecessarily on first boot.

### Release Install

The release server will check for an update from Peridio Cloud a the designated interval. When an update is available, the release server will immediately cache the release metadata to the cache_dir and begin processing the release. Currently, the release server is configured to install an update once it is available. This behavior will change before public release and instead be routed through the update client module. The release server will apply an update in the following order:

* Validate artifact signatures' public key values have been signed by a public key in `trusted_signing_keys`
* Filter the Binaries by uninstalled with a target listed in the `targets` list
* Install Binaries
  * Initialize a Download with an Installer
  * Begin Download (Download Started Event)
  * Download chunks (Download Progress Events)
  * Finish Download (Download Finished Event)
  * Validate hash (during stream)
  * Installer applied (Binary Applied)
  * Update Binary status to complete
* Update Release status to complete

When peridiod installs a release, it will accumulate `reboot_required` and trigger a reboot once all binaries have finished the installation process if any `reboot_required` is true.

See the [Peridio Docs](https://docs.peridio.com/) for more information on configuring Releases for your organization.
## v2.6.2

* Bug fixes
  * Skip Remote Acess Tunnel sync if disabled
  * Force files writes to be synced to disk as they are written to the cache
  * Handle corrupt cached metadata in wireguard config parsing

## v2.6.1

* Bug fixes
  * Update erlexec to revert docs change which broke backwards compatability with > OTP 27

## v2.6.0

* Enhancements
  * Remote Access Tunnels
    * Tunnels that are unknown will be closed and cleaned up
    * Tunnels that are requested while the device was offline will configure and open
    * Tunnels that are known will be resumed
    * Tunnels that are expected to be open but are missing configurations / interfaces will be closed

    This also adds support for configuring a persistent `data_dir` where you want to write tunnel interface configurations in the peridio config. By specifying a persistent location for configurations, tunnels will resume even after device reboots.

    ```json
    "remote_access_tunnels": {
        "enabled": true,
        "data_dir": "/etc/peridiod"
      },
    ```

## v2.5.4

* Enhancement
  * Add support for extending tunnels
* Bug fixes
  * Account for reserved tunnel IPs to prevent a race condition between
    wireguard and subsequent calls to `Peridio.RAT.Network.available_cidrs`

## v2.5.3

* Bug fixes
  * Add additional safety around app start so errors can be presented
  * Fix remote_shell to support Alpine Linux

## v2.5.2

* Enhancement
  * Update `key_pair_source` modules `env` and `uboot` to try to decode base64 values

## v2.5.1

* Bug fixes
  * Device was unable to call tunnel update api properly.

## v2.5.0

* Enhancements
  * Add support for choosing between IEx and getty remote shell
    * `remote_iex: true | false`: Enable / disable the remote console using IEx shell. Useful for Nerves based applications. Setting this to true will take precedence over `remote_shell`.
    * `remote_shell: true | false`. Enable / disable the remote console using a terminal Getty. Useful for all other embedded linux based systems. Requires `socat` to be available on the target.
  * Add support for Remote Access Tunnels. Using this feature will require a Peridio Cloud account with the feature enabled. Contact support@peridio.com for more information.
  * Added support for configuring `peridiod` as an elixir dependency. This is useful if you are consuming `peridiod` as a dependency in a Nerves based application.
  * Configuration will default to reasonable default values if they are unspecified.
  * Added config key `fwup_env: {"KEY": "value", "KEY2": "value2"}`. These key value pairs will be exported into the environment that `fwup` is applied in. This is useful if you need to pass extra arguments passed through the environment.
  * Added config key `fwup_extra_args: ["--unsafe"]`. Useful if you need to pass extra args to `fwup` such as the `--unsafe` flag.

## v2.4.2

* Bug fixes
  * Filter out characters that are not UTF8 before serializing the console.

## v2.4.1

* Enhancements
  * mix release no longer builds a tar into the release directory.

## v2.4.0

* Enhancements
  * Update remote console to present a full getty terminal instead of IEx.

## v2.3.1

* Bug fixes
  * Fixed remote console connectivity issues

## v2.3.0

* Enhancements
  * Add `uboot-env` node configuration for pulling pem encoded x509 certificate
    and private key pair in the U-Boot Environment.

    Example:

    ```json
    "key_pair_source": "uboot-env",
    "key_pair_config": {
      "private_key": "peridio_identity_private_key",
      "certificate": "peridio_identity_certificate"
    }
    ```

## v2.2.0

* Updated default retry parameters to accommodate slow connections like
  NB-IoT 1
* Enhanced debug logging

## v2.1.0

* Updates
  * `PERIDIOD_INCLUDE_ERTS_DIR` is now `MIX_TARGET_INCLUDE_ERTS`
    Change environment variable to be friendly to yocto buikds.
    If you are building peridiod outside yocto, you will need to
    update your build scripts to use the new variable.

## v2.0.1

* Bug Fixes
  * Fix support for using peridiod with Nerves targets
* Enhancements
  * Default the KVBackend to use UBootEnv.

## v2.0.0

* Enhancements
  * Remove dependency on nerves and nerves_hub
  * Add support for Peridio U-Boot environment key names

## v1.1.0

* Enhancements
  * Updated configurator with key_pair_config to allow using pkcs11 or file

Example node settings for different key pair sources:

File:

```elixir
"key_pair_source": "file",
"key_pair_config": {
  "private_key_path": "/etc/peridiod/device-key.pem",
  "certificate_path": "/etc/peridiod/device-cert.pem"
}
```

PKCS11:

```elixir
"key_pair_source": "pkcs11",
"key_pair_config": {
  "key_id": "pkcs11:token=MCHP;object=device;type=private",
  "cert_id": "pkcs11:token=MCHP;object=device;type=cert"
}
```

## v1.0.0

Initial release
