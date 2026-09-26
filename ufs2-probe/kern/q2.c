#include <sys/param.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <ufs/ffs/fs.h>
/* q2 img [zeromagic]: print flags and the quota2 header */
int main(int c, char **v) {
	static union { struct fs fs; char b[SBLOCKSIZE]; } u;
	int fd = open(v[1], c > 2 ? O_RDWR : O_RDONLY);
	if (fd < 0 || pread(fd, u.b, SBLOCKSIZE, SBLOCK_UFS2) != SBLOCKSIZE)
		return 1;
	printf("%s: flags=%#x quota_magic=%#x quota_flags=%#x quotafile=%llu,%llu\n",
	    v[1], u.fs.fs_flags, u.fs.fs_quota_magic, u.fs.fs_quota_flags,
	    (unsigned long long)u.fs.fs_quotafile[0],
	    (unsigned long long)u.fs.fs_quotafile[1]);
	if (c > 2) {
		u.fs.fs_quota_magic = 0;
		if (pwrite(fd, u.b, SBLOCKSIZE, SBLOCK_UFS2) != SBLOCKSIZE)
			return 1;
	}
	return 0;
}
