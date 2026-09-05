"""fork-resolve-package-json.py [package.json]

Resolve package.json conflicts after fork-sync.sh: keep the fork side of the
name/version/description block, take upstream for everything else
(dependencies, engines).
"""
import re,sys
p=sys.argv[1] if len(sys.argv)>1 else 'package.json'; s=open(p).read()
def resolve(m):
    ours, theirs = m.group(1), m.group(2)
    if '"name"' in ours or '"version"' in ours: return ours   # identity block stays fork
    return theirs                                              # everything else follows upstream
s=re.sub(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', resolve, s, flags=re.S)
open(p,'w').write(s)
