#!/usr/bin/env python3
import subprocess
import os

def write_file(filename, data, permissions=None, dirname=None):
    if dirname is not None:
        filename = os.path.join(dirname, filename)

    target_dir = os.path.dirname(filename)
    if not os.path.exists(target_dir):
        os.makedirs(target_dir)

    if permissions is not None:
        subprocess.call(["touch", filename])
        subprocess.call(["chmod", permissions, filename])

    with open(filename, "w", encoding="utf-8") as text_file:
        print(data, file=text_file, end="")


def generate_wg_keypair():
    private_key = subprocess.check_output(["wg", "genkey"])
    public_key = subprocess.check_output(["wg", "pubkey"], input=private_key)
    return private_key.decode("utf-8").strip(), public_key.decode("utf-8").strip()


private_key, public_key = generate_wg_keypair()

write_file("private_key", private_key, "0600", dirname="volumes/vpnrouter")
write_file("public_key", public_key, "0600", dirname="volumes/vpnrouter")

print(" - Private wireguard key saved to ../volumes/vpnrouter/private_key")
print(" - Public key to import to API server saved to ../volumes/vpnrouter/public_key")
