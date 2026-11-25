/*
 * 試験の VM の中で使う小さな道具。
 *	nsec file sec nsec	utimensat() に、検査なしの秒とナノ秒を渡す
 *	excl file		O_EXCL で作る (NFSv3 の exclusive create になる)
 */
#include <sys/stat.h>

#include <err.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	struct timespec ts[2];
	int fd;

	if (argc == 5 && strcmp(argv[1], "nsec") == 0) {
		ts[0].tv_sec = ts[1].tv_sec = strtoll(argv[3], NULL, 0);
		ts[0].tv_nsec = ts[1].tv_nsec = strtol(argv[4], NULL, 0);
		if (utimensat(AT_FDCWD, argv[2], ts, 0) == -1)
			err(1, "utimensat");
		return 0;
	}
	if (argc == 3 && strcmp(argv[1], "excl") == 0) {
		fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL, 0644);
		if (fd == -1)
			err(1, "open");
		close(fd);
		return 0;
	}
	errx(2, "usage: nsec file sec nsec | excl file");
}
