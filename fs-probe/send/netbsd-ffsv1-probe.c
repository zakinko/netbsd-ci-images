/*
 * 試験の VM の中で使う小さな道具。
 *	nsec file sec nsec	utimensat() に、検査なしの秒とナノ秒を渡す
 *	excl file		O_EXCL で作る (NFSv3 の exclusive create になる)
 *	nfsx host dir name w0 w1
 *		NFSv3 の CREATE を EXCLUSIVE で、同じ verifier (w0, w1) の
 *		まま二度送る。二度目は、返事を受け取れなかった client の
 *		送り直しと同じで、サーバは verifier を見比べて成功を返す
 *		はずのもの。xid が違うので、サーバの重複検出には掛からない。
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>

#include <netinet/in.h>
#include <arpa/inet.h>

#include <rpc/rpc.h>

#include <err.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct fh {
	u_int len;
	char data[64];
};

struct mntres {
	u_int status;
	struct fh fh;
};

struct crargs {
	struct fh *fh;
	char *name;
	char verf[8];
};

static bool_t
xdr_mntres(XDR *x, struct mntres *r)
{
	char *p = r->fh.data;

	if (!xdr_u_int(x, &r->status))
		return FALSE;
	if (r->status != 0)
		return TRUE;
	/* 後ろに続く auth の一覧は読まない */
	return xdr_bytes(x, &p, &r->fh.len, sizeof(r->fh.data));
}

static bool_t
xdr_crargs(XDR *x, struct crargs *a)
{
	char *p = a->fh->data;
	u_int mode = 2;		/* EXCLUSIVE */

	return xdr_bytes(x, &p, &a->fh->len, sizeof(a->fh->data)) &&
	    xdr_string(x, &a->name, 255) && xdr_u_int(x, &mode) &&
	    xdr_opaque(x, a->verf, sizeof(a->verf));
}

static CLIENT *
client(const char *host, u_long prog, u_long vers)
{
	struct sockaddr_in sin;
	CLIENT *cl;
	int s;

	memset(&sin, 0, sizeof(sin));
	sin.sin_len = sizeof(sin);
	sin.sin_family = AF_INET;
	if (inet_pton(AF_INET, host, &sin.sin_addr) != 1)
		errx(1, "%s: not an address", host);
	if ((s = socket(AF_INET, SOCK_STREAM, 0)) == -1)
		err(1, "socket");
	if (bindresvport(s, NULL) == -1)
		err(1, "bindresvport");
	if ((cl = clnttcp_create(&sin, prog, vers, &s, 0, 0)) == NULL)
		errx(1, "%s", clnt_spcreateerror("clnttcp_create"));
	cl->cl_auth = authunix_create_default();
	return cl;
}

static int
nfsx(char **argv)
{
	struct timeval tv = { 20, 0 };
	struct mntres mr;
	struct crargs a;
	CLIENT *cl;
	char *dir = argv[1];
	uint32_t w;
	u_int st[2];
	int i;

	cl = client(argv[0], 100005, 3);
	memset(&mr, 0, sizeof(mr));
	if (clnt_call(cl, 1, (xdrproc_t)xdr_wrapstring, &dir,
	    (xdrproc_t)xdr_mntres, &mr, tv) != RPC_SUCCESS)
		errx(1, "%s", clnt_sperror(cl, "mount"));
	if (mr.status != 0)
		errx(1, "mount: status %u", mr.status);

	cl = client(argv[0], 100003, 3);
	a.fh = &mr.fh;
	a.name = argv[2];
	w = htonl((uint32_t)strtoul(argv[3], NULL, 0));
	memcpy(a.verf, &w, 4);
	w = htonl((uint32_t)strtoul(argv[4], NULL, 0));
	memcpy(a.verf + 4, &w, 4);
	for (i = 0; i < 2; i++) {
		st[i] = 9999;
		if (clnt_call(cl, 8, (xdrproc_t)xdr_crargs, &a,
		    (xdrproc_t)xdr_u_int, &st[i], tv) != RPC_SUCCESS)
			errx(1, "%s", clnt_sperror(cl, "create"));
	}
	printf("first %u again %u\n", st[0], st[1]);
	return 0;
}

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
	if (argc == 7 && strcmp(argv[1], "nfsx") == 0)
		return nfsx(argv + 2);
	errx(2, "usage: nsec file sec nsec | excl file | "
	    "nfsx host dir name w0 w1");
}
