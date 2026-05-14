#!/usr/bin/env python3
"""
decrypt_vaulted_items.py — Decrypt an Ansible Vault-encrypted YAML file
(the OpenBao init-keys file) and display all keys or a single named key.

Usage:
    python3 decrypt_vaulted_items.py \\
        --vault-password-file /opt/openbao/.vault-pass \\
        /opt/openbao/init-keys.yml

    # Show only the root_token field:
    python3 decrypt_vaulted_items.py \\
        --vault-password-file /opt/openbao/.vault-pass \\
        --key root_token \\
        /opt/openbao/init-keys.yml
"""

import argparse
import subprocess
import sys
import yaml


def decrypt_file(vault_file: str, vault_pass_file: str) -> str:
    """Return the decrypted plaintext of an Ansible Vault-encrypted file."""
    result = subprocess.run(
        [
            "ansible-vault",
            "decrypt",
            "--vault-password-file",
            vault_pass_file,
            "--output",
            "-",
            vault_file,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: ansible-vault decrypt failed:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Decrypt an Ansible Vault-encrypted YAML file and inspect its contents.",
    )
    parser.add_argument(
        "vault_file",
        metavar="VAULT_FILE",
        help="Path to the Ansible Vault-encrypted YAML file (e.g. /opt/openbao/init-keys.yml)",
    )
    parser.add_argument(
        "--vault-password-file",
        required=True,
        metavar="PATH",
        help="Path to the file containing the Ansible Vault password (e.g. /opt/openbao/.vault-pass)",
    )
    parser.add_argument(
        "--key",
        metavar="KEY",
        default=None,
        help="Print only the value of this top-level YAML key. Omit to print all keys.",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        help="Print the raw decrypted YAML without further parsing.",
    )
    args = parser.parse_args()

    plaintext = decrypt_file(args.vault_file, args.vault_password_file)

    if args.raw:
        print(plaintext, end="")
        return

    try:
        data = yaml.safe_load(plaintext)
    except yaml.YAMLError as exc:
        print(f"ERROR: Failed to parse decrypted YAML: {exc}", file=sys.stderr)
        sys.exit(1)

    if not isinstance(data, dict):
        print("ERROR: Decrypted content is not a YAML mapping.", file=sys.stderr)
        sys.exit(1)

    if args.key:
        if args.key not in data:
            available = ", ".join(sorted(data.keys()))
            print(
                f"ERROR: Key '{args.key}' not found. Available keys: {available}",
                file=sys.stderr,
            )
            sys.exit(1)
        value = data[args.key]
        if isinstance(value, list):
            for item in value:
                print(item)
        else:
            print(value)
    else:
        for key, value in data.items():
            if isinstance(value, list):
                print(f"{key}:")
                for item in value:
                    print(f"  - {item}")
            else:
                print(f"{key}: {value}")


if __name__ == "__main__":
    main()
