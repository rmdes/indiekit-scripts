"""fork-resolve-conflicts.py <file> <spec...>

Resolve every conflict block in <file>, in order, with one spec each:
  ours    keep the fork side
  theirs  keep the upstream side
  @path   replace the block with the contents of that file
"""
import re,sys
p=sys.argv[1]; specs=sys.argv[2:]
s=open(p).read()
blocks=re.findall(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', s, flags=re.S)
assert len(blocks)==len(specs), (p, len(blocks), len(specs))
it=iter(zip(blocks,specs))
def pick(m):
    (ours,theirs),spec=next(it)
    if spec=='ours': return ours
    if spec=='theirs': return theirs
    return open(spec[1:]).read()
s=re.sub(r'<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n', pick, s, flags=re.S)
open(p,'w').write(s)
