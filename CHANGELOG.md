# peridiod releases

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
