# Peridio Daemon

## Configuring

Peridiod is configured via a json formatted file on the filesystem. The location of the file defaults to `$XDG_CONFIG_HOME/peridio/peridio-config.json`. if `$XDG_CONFIG_HOME` is not set the default path is `$HOME/.config/peridio/peridio-config.json`. This file location can be overwritten by setting `PERIDIO_CONFIG_FILE=/path/to/peridio.json`. The peridiod configuration has the following top level keys:

* `version`: The configuration version number. Currently this is 1.
* `device_api`: Configuration for the device api endpoint
  * `certificate_path`: Path to the device api ca certificate.
  * `url`: The peridio server device api URL.
  * `verify`: Enable client side ssl verification for device api connections.
* `fwup`: Keys related to the use of fwup for the last mile.
  * `devpath`: The block storage device path to use for applying firmware updates.
  * `public_keys`: A list of authorized public keys used when verifying update archives.
  * `extra_args`: A list of extra arguments to pass to the fwup command used for applying fwup archives. Helpful when needing to use the --unsafe flag in fwup.
  * `env`: A json object of `"ENV_VAR": "value"` pairs to decorate the environment which fwup is executed from.
* `remote_shell`: Enable or disable the remote getty feature.
* `remote_iex`: Enable or disable the remote IEx feature. Useful if you are deploying a Nerves distribution. Enabling this takes precedence over `remote_shell`
* `node`: Node configuration settings
  * `key_pair_source`: Options are `file`, `uboot-env`, `pkcs11`. This determines the source of the identity key information.
  * `key_pair_config`: Different depending on the `key_pair_source`

    `key_pair_source: file`:
      * `private_key_path`: Path on the filesystem to a PEM encoded private key file.
      * `certificate_path`: Path on the filesystem to a PEM encoded x509 certificate file.

    `key_pair_source: uboot-env`:
      * `private_key`: The key in the uboot environment which contains a PEM encoded private key.
      * `certificate`: The key in the uboot environment which contains a PEM encoded x509 certificate.

    `key_pair_source: pkcs11`:
      * `key_id`: The `PKCS11` URI used to for private key operations.
        Examples:
        ATECCx08 TNG using CryptoAuthLib: `pkcs11:token=MCHP;object=device;type=private`
      * `cert_id`: The `PKCS11` URI used for certificate operations.
        Examples:
        ATECCx08 TNG using CryptoAuthLib: `pkcs11:token=MCHP;object=device;type=cert`

More information about certificate auth can be found in the [Peridio Documentation](docs.peridio.com)

### Example Configurations

#### Common

```json
{
  "version": 1,
  "device_api": {
    "certificate_path": "/etc/peridiod/peridio-cert.pem",
    "url": "device.cremini.peridio.com",
    "verify": true
  },
  "fwup": {
    "devpath": "/dev/mmcblk1",
    "public_keys": ["I93H7n/jHkfNqWik9uZf82Vi/HJuZ24EQBJnAtj9svU="]
  },
  "remote_shell": true,
  "node": {
    // ... see Node Configuration
  }
}
```

#### Node Configurations

Filesystem

```json
"key_pair_source": "file",
"key_pair_config": {
  "private_key_path": "/etc/peridiod/device-key.pem",
  "certificate_path": "/etc/peridiod/device.pem"
}
```

U-Boot Environment

```json
"key_pair_source": "uboot-env",
"key_pair_config": {
  "private_key": "peridio_identity_private_key",
  "certificate": "peridio_identity_certificate"
}
```

System Environment

```json
"key_pair_source": "env",
"key_pair_config": {
  "private_key": "PERIDIO_PRIVATE_KEY",
  "certificate": "PERIDIO_CERTIFICATE"
}
```

PKCS11 Identity using ATECC608B TrustAndGo

```json
"key_pair_source": "pkcs11",
"key_pair_config": {
  "key_id": "pkcs11:token=MCHP;object=device;type=private",
  "cert_id": "pkcs11:token=MCHP;object=device;type=cert"
}
```

### Configuring with Elixir

The peridiod application can be set using config.exs in a Nerves based application. The following is an example of the keys that can be set:

```elixir
config :peridiod,
  device_api_host: "device.cremini.peridio.com",
  device_api_port: 443,
  device_api_sni: "device.cremini.peridio.com",
  device_api_verify: :verify_peer,
  device_api_ca_certificate_path: nil,
  key_pair_source: "env",
  key_pair_config: %{"private_key" => "PERIDIO_PRIVATE_KEY", "certificate" => "PERIDIO_CERTIFICATE"},
  fwup_public_keys: [],
  fwup_devpath: "/dev/mmcblk0",
  fwup_env: [],
  fwup_extra_args: [],
  remote_shell: false,
  remote_iex: true,
```

## Running with Docker

You can debug using docker by generating an SSL certificate and private key pair that is trusted by Peridio Cloud and pass it into the container.

Building the container:

```bash
docker build --tag peridio/peridiod .
```

Running the container:

```bash
podman run -it --rm --env PERIDIO_CERTIFICATE="$(cat /path/to/end-entity-certificate.pem)" --env PERIDIO_PRIVATE_KEY="$(cat /path/to/end-entity-private-key.pem)" --cap-add=NET_ADMIN peridio/peridiod:latest
```

The container will be built using the `peridio.json` configuration file in the support directory. For testing you can modify this as you please. It is configured by default to allow testing for the remote shell and even firmware updates using deployments. You can create firmware to test for deployments using the following:

```bash
PERIDIO_META_PRODUCT=peridiod \
PERIDIO_META_DESCRIPTION=peridiod-dev \
PERIDIO_META_VERSION=1.0.1 \
PERIDIO_META_PLATFORM=docker \
PERIDIO_META_ARCHITECTURE=docker \
PERIDIO_META_AUTHOR=peridio \
fwup -c -f support/fwup.conf -o support/peridiod.fw
```

Then sign the firmwaare using a key pair that is trusted by Peridio Cloud

```bash
fwup --sign -i support/peridiod.fw -o support/peridiod-signed.fw --public-key "$(cat ./path/to/fwup-key.pub)" --private-key "$(cat /path/to/fwup-key.priv)"
```

You can then upload `support/peridiod-signed.fw` to Peridio Cloud and configure a deployment. The container will not actually apply anything persistent, but it will simulate downloading and applying an update.
