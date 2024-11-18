# peridiod releases

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
