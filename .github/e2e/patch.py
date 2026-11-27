# patch.py <index.js>: point the action at the forks under test.
#   anyvm.py   -> zakinko/anyvm netbsd-powerpc-alpha (powerpc/alpha support)
#   images     -> this repo's temporary release v9.9.9
import sys
p = sys.argv[1]
s = open(p, newline="").read()
nl = "\r\n" if "\r\n" in s else "\n"
u = "  const anyvmUrl = `https://github.com/anyvm-org/anyvm/releases/download/v${anyvmVersion}/anyvm.py`;"
if s.count(u) != 1:
    u = u[2:]
    assert s.count(u) == 1, "anyvmUrl not found"
s = s.replace(u, u.replace("https://github.com/anyvm-org/anyvm/releases/download/v${anyvmVersion}/anyvm.py",
              "https://raw.githubusercontent.com/zakinko/anyvm/netbsd-powerpc-alpha/anyvm.py"))
a = "      await downloadFile(anyvmUrl, anyvmPath);" + nl
assert s.count(a) == 1, s.count(a)
js = '''      {
        const e2efs = await import("node:fs");
        const src = e2efs.readFileSync(anyvmPath, "utf8");
        const from = 'brepo = "anyvm-org/{}-builder".format(config[\\'os\\'])';
        if (!src.includes(from)) throw new Error("e2e: brepo not found");
        e2efs.writeFileSync(anyvmPath, src.replace(from, 'brepo = "zakinko/netbsd-ci-images"'));
        core.info("e2e: brepo replaced");
      }
'''.replace("\n", nl)
open(p, "w", newline="").write(s.replace(a, a + js))
