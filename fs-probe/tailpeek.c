/*
 * tailpeek <file>: map the page that holds EOF and count the non-zero
 * bytes past EOF in it.  POSIX requires them to read as zero.
 */
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	struct stat st;
	long pg = sysconf(_SC_PAGESIZE);
	off_t base;
	unsigned char *p;
	long i, n = 0;
	int fd;

	if (argc != 2 || (fd = open(argv[1], O_RDONLY)) < 0 ||
	    fstat(fd, &st) < 0 || st.st_size == 0)
		return 2;
	base = st.st_size / pg * pg;
	p = mmap(NULL, (size_t)pg, PROT_READ, MAP_SHARED, fd, base);
	if (p == MAP_FAILED)
		return 2;
	for (i = st.st_size - base; i < pg; i++)
		n += p[i] != 0;
	printf("%ld\n", n);
	return 0;
}
