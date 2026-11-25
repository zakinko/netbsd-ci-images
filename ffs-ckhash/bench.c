/*
 * bench: known answers for the CRC32C of ffs_ckhash.c, and the time
 * it takes over one 32 KB cylinder group, with the crc32 instruction
 * and with the tables.  Built against the tree under test:
 *   cc -O2 -I<v>/include -I<v>/src -o bench bench.c
 */
#include <sys/param.h>
#include <sys/sysctl.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#include "ffs_ckhash.c"

static double
run(const uint8_t *buf, size_t len, int n, uint32_t *sum)
{
	struct timespec a, b;
	uint32_t c = 0;
	int i;

	clock_gettime(CLOCK_MONOTONIC, &a);
	for (i = 0; i < n; i++)
		c ^= ffs_cg_ckhash(buf, len) + (uint32_t)i;
	clock_gettime(CLOCK_MONOTONIC, &b);
	*sum = c;
	return ((double)(b.tv_sec - a.tv_sec) * 1e9 +
	    (double)(b.tv_nsec - a.tv_nsec)) / n / 1e3;
}

int
main(void)
{
	static uint8_t buf[32768];
	char cpu[128] = "?";
	size_t i, l = sizeof(cpu);
	uint32_t k, sum[2] = { 0, 0 };
	double us;
	int pass, first = 1, npass = 0;

	(void)sysctlbyname("machdep.cpu_brand", cpu, &l, NULL, 0);
	printf("cpu: %s\n", cpu);
	ffs_ckhash_init();
	for (i = 0; i < sizeof(buf); i++)
		buf[i] = (uint8_t)(i * 31 + (i >> 8));
#ifdef CRC32C_INSN
	printf("crc32 instruction: %s\n", crc32c_insn ? "yes" : "no");
	first = crc32c_insn ? 0 : 1;
#endif
	for (pass = first; pass < 2; pass++) {
		const char *how = pass == 0 ? "instruction" : "tables";

#ifdef CRC32C_INSN
		if (pass == 1)
			crc32c_insn = false;
#endif
		k = crc32c_update(~0U, (const uint8_t *)"123456789", 9);
		printf("%s: 123456789 -> %08x %s\n", how, k,
		    k == 0x1cf96d7cU ? "ok" : "BAD");
		k = ffs_cg_ckhash(buf + 1, sizeof(buf) - 3);
		printf("%s: odd address and length -> %08x\n", how, k);
		us = run(buf, sizeof(buf), 20000, &sum[pass]);
		printf("%s: 32 KB cylinder group %.2f us\n", how, us);
		sum[pass] ^= k;
		npass++;
	}
	if (npass == 2)
		printf("instruction and tables agree: %s\n",
		    sum[0] == sum[1] ? "yes" : "NO");
	return 0;
}
