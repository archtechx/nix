#!/usr/bin/env bash

set -xe

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 <ip-address> <ssh-pubkey-path>"
    exit 1
fi

IP=$1
SSHKEYPATH=$2

TMPDIR=$(mktemp -d)

cleanup() {
    rm -rf "$TMPDIR"
}

trap cleanup EXIT

cp configuration.nix "$TMPDIR/configuration.nix"
sed -i.bak "s|# REPLACEME|\"$(cat "$SSHKEYPATH" | tr -d '\n')\"|" "$TMPDIR/configuration.nix"

echo "$TMPDIR/configuration.nix"

ssh "root@$IP" "nixos-generate-config"
scp "$TMPDIR/configuration.nix" "root@$IP:/etc/nixos/configuration.nix"
scp flake.nix "root@$IP:/etc/nixos/flake.nix"
if [ -f flake.lock ]; then
    scp flake.lock "root@$IP:/etc/nixos/flake.lock"
fi
ssh "root@$IP" "nixos-rebuild switch"

# Copy the lockfile back.
# This will create a dirty git state but the lock file may be desirable when
# deploying to multiple servers to keep things in sync and reuse more cache.
scp "root@$IP:/etc/nixos/flake.lock" flake.lock
