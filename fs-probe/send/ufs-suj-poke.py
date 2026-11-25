# image の superblock を読み書きする
#   get <img>            fs_clean
#   clean <img> <n>      fs_clean を n に
#   nohash <img>         fs_metackhash と印を消し、fs_flags を SU|SUJ に
#   allfree <img>        全 cg の空き表を全部空きにする (解放で ufs_error)
import struct, sys
cmd, img = sys.argv[1:3]
f = open(img, 'r+b')
for sb in (65536, 8192):
    f.seek(sb + 1372)
    if struct.unpack('<I', f.read(4))[0] in (0x19540119, 0x011954):
        break
def u32(o):
    f.seek(sb + o); return struct.unpack('<I', f.read(4))[0]
if cmd == 'get':
    f.seek(sb + 209); print(f.read(1)[0])
elif cmd == 'clean':
    f.seek(sb + 209); f.write(bytes([int(sys.argv[3])]))
elif cmd == 'nohash':
    f.seek(sb + 1308); f.write(struct.pack('<II', 0, 0x0a))
elif cmd == 'allfree':
    cblkno, ncg, fsize, fpg = u32(12), u32(44), u32(52), u32(188)
    for c in range(ncg):
        o = (c * fpg + cblkno) * fsize
        f.seek(o + 4); assert struct.unpack('<I', f.read(4))[0] == 0x090255
        f.seek(o + 20); nd = struct.unpack('<I', f.read(4))[0]
        f.seek(o + 96); fo = struct.unpack('<I', f.read(4))[0]
        f.seek(o + fo); f.write(b'\xff' * (nd // 8))
f.close()
