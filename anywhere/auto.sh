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
cp flake.nix "$TMPDIR/flake.nix"
if [ -f flake.lock ]; then
    cp flake.lock "$TMPDIR/flake.lock"
fi
cp disk-config.nix "$TMPDIR/disk-config.nix"
sed -i.bak "s|# REPLACEME|\"$(cat "$SSHKEYPATH" | tr -d '\n')\"|" "$TMPDIR/configuration.nix"

(cd "$TMPDIR" && nix run nixpkgs#nixos-anywhere -- --flake .#cloud root@$IP)

# Copy the lockfile back.
# This will create a dirty git state but the lock file may be desirable when
# deploying to multiple servers to keep things in sync and reuse more cache.
cp "$TMPDIR/flake.lock" flake.lock
