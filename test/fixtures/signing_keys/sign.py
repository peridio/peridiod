import os
import argparse
import hashlib
import binascii
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend


def load_private_key():
    script_dir = os.path.dirname(os.path.realpath(__file__))
    file = os.path.join(script_dir, "trusted-key-private.pem")
    with open(file, "rb") as key_file:
        private_key = serialization.load_pem_private_key(
            key_file.read(), password=None, backend=default_backend()
        )
    return private_key


def sha256_hash_file(file_path):
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        while chunk := f.read(8192):
            sha256.update(chunk)
    return sha256.digest()


def main():
    parser = argparse.ArgumentParser(
        description="SHA-256 hash a file and sign it with an ED25519 private key."
    )
    parser.add_argument("file_path", help="Path to the file to be hashed")
    args = parser.parse_args()

    private_key = load_private_key()
    file_hash = sha256_hash_file(args.file_path)
    file_hash_hex = binascii.hexlify(file_hash).lower()
    signature = private_key.sign(file_hash_hex)
    signature_hex = binascii.hexlify(signature).upper()

    print("SHA-256 Hash (Base16):", file_hash_hex.decode("utf-8"))
    print("Signature (Base16 Upper):", signature_hex.decode("utf-8"))


if __name__ == "__main__":
    main()
