# netbsd-ci-images

Plain OS disk images for booting under an emulator from CI.
日本語 (primary): [README.md](README.md) / status: [SUPPORT.md](SUPPORT.md)

NetBSD is the focus, but anything that runs under an emulator and can be
reached over ssh belongs here.

What upstreams ship is mostly installers (ISO and `install.img`).
Ready-to-run images are rare: for NetBSD only amd64 from 10.0 on, nothing for
i386, nothing before 9.x, and nothing at all for the other ports. Running an
install on every CI job is not practical, so the images are built once here
and published as a release.

## What is in them

Nothing is tailored to a particular use. The distribution is unpacked, `sshd`
is enabled, and `root`'s `authorized_keys` is placed. That is all.

- For NetBSD every set present in that release is installed (including X when
  `xbase`/`xserver` exist), so `Xvfb` is available for headless testing
- Swap is off
- **No key is baked in.** The guest fetches one from the host at boot (below)

## Booting

How to attach an image is written in the `<name>.qemu` file next to it. Do not
hardcode it: if the wiring disagrees with the image, the kernel will not find
root.

### NetBSD

```sh
sh runvm.sh i386-10.1 2222      # boot and wait for ssh
$(cat i386-10.1.ssh) uname -a   # runvm.sh also writes out how to get in
sh stopvm.sh i386-10.1          # shut down properly (pulling the plug breaks FFS)
```

Some ports need more than the image; those files are published alongside it.

| port | needs | why |
| --- | --- | --- |
| alpha | `.kernel` | QEMU's alpha has no SRM |
| macppc | `.bootiso` | cannot boot from FFS, so boot off a CD. The kernel asks `root device:` on every boot; `console.py` answers |
| evbarm | `.kernel` `.dtb` | no boot loader involved |
| evbarm64 riscv64 | `.kernel` | same |
| pmax hpcmips landisk | `.kernel` | passed to gxemul |

**The gxemul and simh ports (pmax hpcmips landisk vax) cannot be reached over
ssh.** Neither emulator has user networking or port forwarding, so there is no
way in from the host. They are known to boot; use the console.

### FreeBSD

```sh
sh build.sh freebsd-14.3-amd64
$(cat out/freebsd-14.3-amd64.ssh) uname -a
```

The official VM image is used as-is, but **as-is you see nothing**. Three
quirks:

1. **With a VGA device present, the firmware and the loader talk only to the
   screen.** Pointing `-serial` at a socket yields not one byte, and
   `-vga none` does not change it. Only `-nographic` puts them on the serial
   line
2. **The kernel console ships as Video only.** In the loader menu, `5` toggles
   it to `Cons: Dual (Serial primary)`, then `1` boots multi user.
   **Enter does not work** — the loader waits for CR, not LF — so press the
   number
3. **There are no host keys.** `sshd_enable=YES` alone fails with
   `No host key files found`; `ssh-keygen -A` is required

### SunOS 4.1.4 (sparc)

```sh
sh build.sh sunos-4.1.4-sparc
```

Runs on QEMU's SS-5. **No proprietary PROM is needed** — QEMU's bundled
OpenBIOS boots it. Three quirks:

- root has no password, and **root's shell is csh**, so `2>&1` is a syntax
  error. Wrap anything non-trivial in `sh -c`
- **The IP address is baked in** and does not match QEMU's user networking.
  SunOS 4 has no DHCP, so it is reset with `ifconfig le0 10.0.2.15` and
  `route add default 10.0.2.2`
- There is no gcc and `/bin/cc` is K&R only, so **ssh is not working yet**
  (see [SUPPORT.md](SUPPORT.md))

## Building

```sh
pip install pexpect https://www.gson.org/netbsd/anita/download/anita-2.18.tar.gz
sudo apt-get install qemu-system-x86 qemu-system-sparc qemu-system-ppc \
    qemu-system-arm qemu-system-misc qemu-utils genisoimage gxemul simh

sh build-image.sh i386 10.1        # NetBSD (anita drives sysinst)
sh build-image.sh riscv64 netbsd-11
sh build.sh freebsd-14.3-amd64     # everything else
```

`build.sh` reads `targets/<name>.conf`. The installation method is chosen by
`DRIVER`:

| DRIVER | method |
| --- | --- |
| `prebuilt` | just boot a ready-made image |
| `anita` | drive sysinst (NetBSD) |
| `autoinstall` | serve an answer file (OpenBSD) |
| `expect` | drive the installer over the console (todo) |
| `builder-vm` | assemble a raw disk inside a NetBSD guest (todo) |

The heart of a recipe is `STEPS`: pairs of "wait for this => type that". The
steps you typed by hand on the console can be copied in verbatim; `talk.py`
replays them.

```
STEPS="login:=>root|#=>ifconfig le0 10.0.2.15 netmask 255.255.255.0 up"
```

The NetBSD sweep runs from the `build-images` GitHub Actions workflow. Ports
times releases is 719 combinations, so one run cannot finish them all: each
run builds `limit` of the ones not published yet, and re-running continues
where it left off.

`anita` reads the last path element of the distribution URL as the port name.
Release trees do not always agree with the name anita expects (`hp700`, or
`evbarm-earmv7hf` which exists only in the daily builds), so a local relay
that answers with 302 (`mirror-alias.py`) lines the names up.

## Keys

**No key is baked into an image.** The guest fetches a public key from the
host — on every boot, or once during setup. `runvm.sh` and `build.sh` generate
a throwaway key pair and serve it.

Baking one in would tell anybody looking at a published image which key opens
root, and would force users to keep the matching private key, which in CI
means a secret. Fetching means **no secret and no fixed key**.

The port used for serving is picked from whatever is free. Only the NetBSD
images are fixed: 8123 is burned into their `rc.d`, so two of them on one
machine fight over it. (This actually happened: another session held the port,
the guest fetched that session's key, and nothing could log in.)

## ssh on old releases

The `sshd` in base speaks different things depending on the release, and the
older it is the less it has in common with today's OpenSSH. For NetBSD:

| release | ssh in base | how to get in |
| --- | --- | --- |
| 6.0 and later | OpenSSH 5.x+ | as-is |
| 2.0 – 5.x | OpenSSH 3.6+ | allow `ssh-rsa`, group1 kex, cbc, hmac-md5 explicitly |
| 1.6.x | OpenSSH 3.4 | same |
| 1.5.x | OpenSSH 2.x | SSH2 is DSA only; build and swap in OpenSSH |
| 1.4 and earlier | none | same |

For 1.5.x and earlier, OpenSSH 3.9p1 is built during image creation. pkgsrc
would be the obvious way, but neither a pkgsrc tree of that vintage nor its
distfiles can be assembled today, so the same work is done straight from the
release tarballs.

The workflow pins `ubuntu-24.04` because its OpenSSH 9.6 can still generate
DSA keys; on newer runners there is no way into a 1.5.x guest.

## Published vs local

Only images whose redistribution is permitted are published. Images built from
locally held commercial Unix media are **never uploaded, neither as a release
asset nor as an artifact**. A recipe's `LICENSE` field switches this, and CI
only looks at `free` targets. See [SUPPORT.md](SUPPORT.md).

## Provenance

NetBSD distribution sets, FreeBSD VM images and the like are used unmodified.
They are BSD licensed.
