#!/usr/bin/env sh

# Args
# 1) PERIDIOD_RELEASE_ARCHIVE
# 2) PERIDIOD_DEB_PACKAGE_DIR
# 

PERIDIOD_RELEASE_ARCHIVE=$1
PERIDIOD_DEB_PACKAGE_DIR=$2

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

mkdir -p "$PERIDIOD_DEB_PACKAGE_DIR/DEBIAN" \
  "$PERIDIOD_DEB_PACKAGE_DIR/opt/peridiod" \
  "$PERIDIOD_DEB_PACKAGE_DIR/etc/peridiod" \
  "$PERIDIOD_DEB_PACKAGE_DIR/usr/lib/systemd/system/" \
  "$PERIDIOD_DEB_PACKAGE_DIR/usr/lib/systemd/system.conf.d"

envsubst < "$SCRIPT_DIR/deb/control" > "$PERIDIOD_DEB_PACKAGE_DIR/DEBIAN/control"
envsubst < "$SCRIPT_DIR/deb/changelog" > "$PERIDIOD_DEB_PACKAGE_DIR/DEBIAN/changelog"
cp release/deb/postinstall "$PERIDIOD_DEB_PACKAGE_DIR/DEBIAN"
cp release/deb/prerm "$PERIDIOD_DEB_PACKAGE_DIR/DEBIAN"

tar -xvf "$PERIDIOD_RELEASE_ARCHIVE" -C "$PERIDIOD_DEB_PACKAGE_DIR/opt/peridiod"
cp release/peridiod.service "$PERIDIOD_DEB_PACKAGE_DIR/usr/lib/systemd/system/"
cp release/peridiod.conf "$PERIDIOD_DEB_PACKAGE_DIR/usr/lib/systemd/system.conf.d/"

dpkg-deb --build "$PERIDIOD_DEB_PACKAGE_DIR"
