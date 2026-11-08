#!/usr/bin/env python3
# 診断用。当て物の組には入れない。ufs の balloc.c に trace_printk を差し込み、
# fragment を取る・移す・解放する時の inode と物理番号を ftrace の buffer に残す。
# 壊れた page の物理番号から来歴を辿るため (ufs-crash.sh の UFS_TRACE)。
#   ufs-trace.py <fs/ufs の dir>
# 目印は mainline と 6.12 の両方に在る UFSD の行。
import re
import sys

path = sys.argv[1] + "/balloc.c"
src = open(path).read()
ino = "(unsigned long long)inode->i_ino"
points = [
	# ufs_free_fragments と ufs_free_blocks
	(r"^\tUFSD\(\"ENTER, fragment %llu, count %u\\n\",$", 2,
	 '\ttrace_printk("ufsfree ino %llu frag %llu count %u\\n", ' + ino +
	 ', (unsigned long long)fragment, (unsigned)count);\n'),
	# ufs_change_blocknr
	(r"^\tUFSD\(\"ENTER, ino %l*u, count %u, oldb %llu, newb %llu\\n\",$", 1,
	 '\ttrace_printk("ufsmove ino %llu beg %llu count %u oldb %llu newb %llu\\n", ' + ino +
	 ', (unsigned long long)beg, (unsigned)count, (unsigned long long)oldb, (unsigned long long)newb);\n'),
	# ufs_change_blocknr が buffer を付け替える前の状態。bh_read() の前に取る。
	(r"^\t\t\tpos = \(i - beg\) \+ j;$", 1,
	 '\t\t\ttrace_printk("ufsbh ino %llu frag %llu old %llu new %llu fdirty %d fwb %d fup %d bmap %d bup %d bdirty %d bnr %llu isize %lld fpos %lld\\n", ' + ino +
	 ', (unsigned long long)(i + j - (i & mask)), (unsigned long long)(oldb + (i - beg) + j), (unsigned long long)(newb + (i - beg) + j)'
	 ', folio_test_dirty(folio), folio_test_writeback(folio), folio_test_uptodate(folio)'
	 ', buffer_mapped(bh), buffer_uptodate(bh), buffer_dirty(bh), (unsigned long long)bh->b_blocknr, (long long)i_size_read(inode), (long long)folio_pos(folio));\n'),
	# ufs_new_fragments の三つの出口
	(r"^\t\tUFSD\(\"EXIT, result %llu\\n\", \(unsigned long long\)result\);$", 3,
	 '\t\ttrace_printk("ufsnew ino %llu frag %llu old %u new %u result %llu\\n", ' + ino +
	 ', (unsigned long long)fragment, (unsigned)oldcount, (unsigned)newcount, (unsigned long long)result);\n'),
]
for pat, want, line in points:
	rx = re.compile(pat, re.M)
	got = len(rx.findall(src))
	if got != want:
		sys.exit("ufs-trace: %d matches for %s, want %d" % (got, pat, want))
	src = rx.sub(lambda m: line + m.group(0), src)
open(path, "w").write(src)
print("ufs-trace: %d trace points in balloc.c" % src.count("trace_printk"))
