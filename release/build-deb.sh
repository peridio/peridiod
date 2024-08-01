#!/usr/bin/env sh

set -e

# Args
# 1) PERIDIOD_RELEASE_ARCHIVE: path to the release archive
# 2) PERIDIOD_PACKAGE_DIR: path to the package build dir

PERIDIOD_RELEASE_ARCHIVE=$1
PERIDIOD_PACKAGE_DIR=$2

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

mkdir -p "$PERIDIOD_PACKAGE_DIR/DEBIAN" \
  "$PERIDIOD_PACKAGE_DIR/usr/lib/peridiod" \
  "$PERIDIOD_PACKAGE_DIR/etc/peridiod" \
  "$PERIDIOD_PACKAGE_DIR/usr/lib/systemd/system/"

envsubst < "$SCRIPT_DIR/deb/control" > "$PERIDIOD_PACKAGE_DIR/DEBIAN/control"
envsubst < "$SCRIPT_DIR/deb/changelog" > "$PERIDIOD_PACKAGE_DIR/DEBIAN/changelog"
cp "$SCRIPT_DIR/deb/postinstall" "$PERIDIOD_PACKAGE_DIR/DEBIAN"
cp "$SCRIPT_DIR/deb/prerm" "$PERIDIOD_PACKAGE_DIR/DEBIAN"

tar -xvf "$PERIDIOD_RELEASE_ARCHIVE" -C "$PERIDIOD_PACKAGE_DIR/usr/lib/peridiod"
cp "$SCRIPT_DIR/peridiod.service" "$PERIDIOD_PACKAGE_DIR/usr/lib/systemd/system/"
cp "$SCRIPT_DIR/peridiod.env" "$PERIDIOD_PACKAGE_DIR/etc/peridiod/"
cp "$SCRIPT_DIR/pkg-peridio.json" "$PERIDIOD_PACKAGE_DIR/etc/peridiod/peridio.json"

dpkg-deb --build "$PERIDIOD_PACKAGE_DIR"
