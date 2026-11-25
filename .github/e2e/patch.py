import sys
p = sys.argv[1]
s = open(p).read()
a = "      await downloadFile(anyvmUrl, anyvmPath);\n"
assert s.count(a) == 1, s.count(a)
js = '''      {
        const e2efs = await import("node:fs");
        const src = e2efs.readFileSync(anyvmPath, "utf8");
        const from = 'brepo = "anyvm-org/{}-builder".format(config[\\'os\\'])';
        if (!src.includes(from)) throw new Error("e2e: brepo not found");
        e2efs.writeFileSync(anyvmPath, src.replace(from, 'brepo = "zakinko/netbsd-ci-images"'));
        core.info("e2e: brepo replaced");
      }
'''
open(p, "w").write(s.replace(a, a + js))
