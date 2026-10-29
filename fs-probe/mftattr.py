# mftattr.py <device> <inode>...: print each inode's $DATA attribute record
# in hex, read straight from the MFT.  The record layout (FILE header,
# update sequence fixups, attribute headers) is from the NTFS on-disk
# format as ntfs-3g's layout.h and fs/ntfs3/ntfs.h both define it.
import struct
import sys

dev = open(sys.argv[1], 'rb')
boot = dev.read(512)
bps, spc = struct.unpack_from('<HB', boot, 0x0b)
mft_lcn, = struct.unpack_from('<q', boot, 0x30)
cpr, = struct.unpack_from('<b', boot, 0x40)
cluster = bps * spc
rec_size = cluster * cpr if cpr > 0 else 1 << -cpr

for ino in map(int, sys.argv[2:]):
    # mkntfs lays the MFT out contiguously; the records used here are
    # within its first extent.
    dev.seek(mft_lcn * cluster + ino * rec_size)
    rec = bytearray(dev.read(rec_size))
    usa_off, usa_cnt = struct.unpack_from('<HH', rec, 4)
    usn = rec[usa_off:usa_off + 2]
    for i in range(1, usa_cnt):
        end = i * bps - 2
        if rec[end:end + 2] != usn:
            print(ino, 'fixup mismatch')
        rec[end:end + 2] = rec[usa_off + 2 * i:usa_off + 2 * i + 2]
    off, = struct.unpack_from('<H', rec, 0x14)
    while off + 8 <= rec_size:
        atype, alen = struct.unpack_from('<II', rec, off)
        if atype == 0xffffffff or alen == 0:
            break
        if atype == 0x80:
            print(ino, 'len=%#x' % alen, rec[off:off + alen].hex(' '))
        off += alen
