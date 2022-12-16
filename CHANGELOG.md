# peridiod releases

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
