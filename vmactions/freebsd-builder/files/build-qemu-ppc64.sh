#!/bin/sh
# Build a newer qemu-system-ppc64 for the powerpc64le guests.
#
# The runner's stock QEMU is 8.2.2 (measured: "QEMU emulator version 8.2.2
# (Debian 1:8.2.2+ds-0ubuntu1.18)" on ubuntu-24.04), which is the exact
# version build.py's comment names when it says the FreeBSD powerpc64le
# kernel "takes an early Program Exception under QEMU TCG".  On that QEMU
# the guest does reach the loader and then dies:
#
#   FreeBSD/powerpc64le Open Firmware loader, Revision 3.0
#   Booting [/boot/kernel/kernel]...
#   ( 700 ) Program Exception [ 2000 ]
#
# On 11.1.1 the same ISO boots past that point to the installer prompt.  So
# the fix is a newer QEMU, not a patch -- this script carries no patch, only
# a version.  Same shape as netbsd-builder's files/build-qemu-sparc64.sh.
set -e
QEMU_VER=11.1.1
OUTDIR="$1"
if [ -z "$OUTDIR" ]; then
  echo "usage: $0 <outdir>" >&2
  exit 1
fi
ROOT="$(pwd)"
mkdir -p "$OUTDIR"
OUT="$ROOT/$OUTDIR"

SUDO=sudo
[ "$(id -u)" = 0 ] && SUDO=
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq build-essential ninja-build pkg-config \
  python3-venv libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev \
  zlib1g-dev wget xz-utils zstd >/dev/null

WORK=$(mktemp -d /tmp/qemu-ppc64-build.XXXXXX)
echo "build dir: $WORK (left in place; /tmp is ephemeral)"
cd "$WORK"
wget -q "https://download.qemu.org/qemu-${QEMU_VER}.tar.xz"
tar xf "qemu-${QEMU_VER}.tar.xz"
cd "qemu-${QEMU_VER}"

# Same feature trim as the sparc64 build: no GUI, no docs, no storage or
# remote backends the runtime never uses; slirp + VNC + system fdt kept.
#
# The option list is filtered against this QEMU's own --configure help before
# use.  QEMU drops options between releases -- 11.1.1 no longer knows
# --disable-glusterfs, which the sparc64 script (pinned to 10.2.3) still
# passes, and configure treats an unknown option as a hard error:
#
#   ERROR: unknown option --disable-glusterfs
#
# Filtering means bumping QEMU_VER does not silently break the build again.
# Only the --disable-* trims get filtered.  They are build-time economy and
# nothing depends on them, so dropping one that this QEMU no longer knows is
# harmless.  The --enable-* ones are NOT filtered: they name features the
# runtime actually uses (user networking, VNC), and if one cannot be had we
# want configure to say so rather than hand back a QEMU that fails later at
# "network backend 'user' is not compiled into this binary".
TRIM="--disable-docs --disable-gtk --disable-sdl --disable-opengl
--disable-virglrenderer --disable-spice --disable-smartcard
--disable-usb-redir --disable-libiscsi --disable-rbd --disable-glusterfs
--disable-libnfs --disable-seccomp --disable-linux-aio --disable-libusb
--disable-tpm"
NEED="--enable-slirp --enable-vnc --enable-fdt=system"

./configure --help > "$WORK/help.txt" 2>&1 || true
OPTS=
for o in $TRIM; do
	if grep -q -- "$o" "$WORK/help.txt"; then
		OPTS="$OPTS $o"
	else
		echo "  この QEMU は $o を知らないので落とす (build 時の節約のみ)"
	fi
done
OPTS="$OPTS $NEED"
echo "  configure の option:$OPTS"

./configure --target-list=ppc64-softmmu --prefix="$WORK/install" $OPTS \
  > "$WORK/configure.log" 2>&1 || { tail -40 "$WORK/configure.log"; exit 1; }
make -j"$(nproc)" > "$WORK/make.log" 2>&1 || { tail -40 "$WORK/make.log"; exit 1; }
make install > /dev/null

pkg="$WORK/pkg"
mkdir -p "$pkg/qemu11-ppc64/bin" "$pkg/qemu11-ppc64/share"
cp "$WORK/install/bin/qemu-system-ppc64" "$pkg/qemu11-ppc64/bin/"
# Take the whole share/qemu rather than naming the blobs.  Naming them is how
# this broke once already: the list had slof.bin and the NIC roms, and the
# machine then asked for one that was not on it --
#
#   qemu-system-ppc64: failed to find romfile "vgabios-stdvga.bin"
#
# Which roms a machine loads depends on the devices build.py puts on the
# command line, so an enumerated list is wrong again the moment that changes.
# The directory is a few MB; copying it whole removes the class of error.
cp -r "$WORK/install/share/qemu" "$pkg/qemu11-ppc64/share/qemu"

"$pkg/qemu11-ppc64/bin/qemu-system-ppc64" --version | head -1
out="$OUT/qemu-${QEMU_VER}-ppc64-noble.tar.zst"
tar --zstd -cf "$out" -C "$pkg" qemu11-ppc64
ls -la "$out"
sha256sum "$out"
echo "build-qemu-ppc64: done"
