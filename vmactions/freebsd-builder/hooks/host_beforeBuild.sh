#!/bin/sh
# Build the pinned QEMU before the guest build starts, when the conf asks for
# one and it is not there yet.  Mirrors netbsd-builder's hook of the same name.
set -e
case "${VM_ARCH:-}" in
powerpc64le|ppc64le) ;;
*) exit 0 ;;
esac
if [ -n "${VM_QEMU_TAR:-}" ] && [ ! -e "$VM_QEMU_TAR" ]; then
  echo "host_beforeBuild: building QEMU $VM_QEMU_TAR for $VM_ARCH"
  bash files/build-qemu-ppc64.sh "$(dirname "$VM_QEMU_TAR")"
  test -e "$VM_QEMU_TAR"
fi
