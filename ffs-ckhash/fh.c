/*
 * fh path: take the file handle of path and open the file by it.
 *
 * fhopen(2) goes through ffs_fhtovp(), which reads the cylinder group
 * of the inode to see whether the inode has been initialised.  It
 * changes nothing there.
 */
#include <sys/types.h>
#include <sys/mount.h>
#include <err.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	size_t sz = 0;
	void *fh;
	int fd;

	if (argc != 2)
		return 2;
	if (getfh(argv[1], NULL, &sz) == -1 && sz == 0)
		err(1, "getfh size");
	if ((fh = malloc(sz)) == NULL)
		err(1, "malloc");
	if (getfh(argv[1], fh, &sz) == -1)
		err(1, "getfh");
	if ((fd = fhopen(fh, sz, O_RDONLY)) == -1)
		err(1, "fhopen");
	close(fd);
	return 0;
}
