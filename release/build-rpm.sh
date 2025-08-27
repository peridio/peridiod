#!/usr/bin/env sh

set -e

# Args
# 1) PERIDIOD_RELEASE_ARCHIVE: path to the release archive
# 2) PERIDIOD_PACKAGE_DIR: path to the package build dir

PERIDIOD_RELEASE_ARCHIVE=$1
PERIDIOD_PACKAGE_DIR=$2

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

mkdir -p "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM/peridiod"
mkdir -p "$PERIDIOD_PACKAGE_DIR/RPMS" "$PERIDIOD_PACKAGE_DIR/SOURCES" "$PERIDIOD_PACKAGE_DIR/SPECS" "$PERIDIOD_PACKAGE_DIR/BUILD" "$PERIDIOD_PACKAGE_DIR/BUILDROOT"
tar -xvf "$PERIDIOD_RELEASE_ARCHIVE" -C "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM/peridiod"
cp "$SCRIPT_DIR/peridiod.service" "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM"
cp "$SCRIPT_DIR/peridiod.env" "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM"
cp "$SCRIPT_DIR/pkg-peridio.json" "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM/peridio.json"
cp "$SCRIPT_DIR/peridiod-state" "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM/peridiod-state"

tar -czvf "$PERIDIOD_PACKAGE_DIR/SOURCES/peridiod-$PERIDIOD_VERSION_RPM.tar.gz" -C "$PERIDIOD_PACKAGE_DIR" "peridiod-$PERIDIOD_VERSION_RPM"
rm -rf "$PERIDIOD_PACKAGE_DIR/peridiod-$PERIDIOD_VERSION_RPM"

envsubst < "$SCRIPT_DIR/rpm/spec" > "$PERIDIOD_PACKAGE_DIR/SPECS/peridiod.spec"

rpmbuild -vv -ba --define "_topdir $PERIDIOD_PACKAGE_DIR" --define "_enable_debug_packages 0" --define "debug_package %{nil}" "$PERIDIOD_PACKAGE_DIR/SPECS/peridiod.spec"
rpm -qlp "$PERIDIOD_PACKAGE_DIR/RPMS/$PERIDIOD_ARCH_RPM/peridiod-$PERIDIOD_VERSION_RPM-1.$PERIDIOD_ARCH_RPM.rpm"
