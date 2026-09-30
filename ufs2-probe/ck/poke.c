/*
 * poke img flags          print fs_flags, the check-hash words and quota2 magic
 * poke img sb|cg|ino N    flip one byte inside what the check-hash covers
 *
 * The fields picked are ones nothing else reads, so the only thing
 * wrong afterwards is the check-hash: fs_avgfpdir in the superblock,
 * cg_old_time in cylinder group 0, di_atime in inode N.
 */
#include <sys/param.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <ufs/ufs/dinode.h>
#include <ufs/ffs/fs.h>

static union { struct fs fs; char b[SBLOCKSIZE]; } u;

static void
flip(int fd, off_t off)
{
	unsigned char c;

	if (pread(fd, &c, 1, off) != 1) exit(1);
	c ^= 0x5a;
	if (pwrite(fd, &c, 1, off) != 1) exit(1);
	printf("flipped byte at %jd\n", (intmax_t)off);
}

int
main(int argc, char **argv)
{
	struct fs *fs = &u.fs;
	int fd;

	if (argc < 3) return 2;
	fd = open(argv[1], strcmp(argv[2], "flags") ? O_RDWR : O_RDONLY);
	if (fd < 0 || pread(fd, u.b, SBLOCKSIZE, SBLOCK_UFS2) != SBLOCKSIZE)
		return 1;
	if (strcmp(argv[2], "flags") == 0) {
		printf("%s: magic=%#x flags=%#x ckhash=%#x metackhash=%#x quota_magic=%#x\n",
		    argv[1], fs->fs_magic, fs->fs_flags, fs->fs_sparecon32[24],
		    fs->fs_sparecon32[25], fs->fs_quota_magic);
	} else if (strcmp(argv[2], "sb") == 0) {
		flip(fd, SBLOCK_UFS2 + offsetof(struct fs, fs_avgfpdir));
	} else if (strcmp(argv[2], "cg") == 0) {
		flip(fd, (off_t)FFS_FSBTODB(fs, cgtod(fs, 0)) * DEV_BSIZE +
		    offsetof(struct cg, cg_old_time));
	} else if (strcmp(argv[2], "ino") == 0 && argc > 3) {
		ino_t ino = (ino_t)strtoull(argv[3], NULL, 0);
		flip(fd, (off_t)FFS_FSBTODB(fs, ino_to_fsba(fs, ino)) * DEV_BSIZE +
		    (off_t)ino_to_fsbo(fs, ino) * (off_t)sizeof(struct ufs2_dinode) +
		    offsetof(struct ufs2_dinode, di_atime));
	} else
		return 2;
	return 0;
}
