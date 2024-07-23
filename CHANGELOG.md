# peridiod releases

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
