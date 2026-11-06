
import struct, sys
sys.stdout.reconfigure(encoding="utf-8")
data = open(r"C:\Users\1510\Desktop\moon\mooniso\tools\corpus\rockridge.iso","rb").read()
SECTOR=2048
# find PVD root record
pvd = 16*SECTOR
root_rec = data[pvd+156:pvd+156+34]
def rec_info(rec):
    ln = rec[0]
    ext = struct.unpack("<I", rec[2:6])[0]
    size = struct.unpack("<I", rec[10:14])[0]
    nlen = rec[32]
    name = rec[33:33+nlen]
    sysuse = rec[33+nlen+(1 if nlen%2==0 else 0):ln]
    return ln, ext, size, name, sysuse
ln, ext, size, name, su = rec_info(root_rec)
print("root extent", ext, "size", size, "sysuse", su)
# read root dir entries to find DOCS
base = ext*SECTOR
pos = 0
docs_ext = None
while pos < size:
    ln = data[base+pos]
    if ln == 0:
        pos = ((pos//SECTOR)+1)*SECTOR
        continue
    ln, ext2, size2, name2, su2 = rec_info(data[base+pos:base+pos+ln])
    print("root entry", name2, "ext", ext2, "flags", data[base+pos+25], "susp", su2)
    if name2 == b"DOCS":
        docs_ext = ext2
    pos += ln
# dump DOCS records with susp entries
base = docs_ext*SECTOR
pos = 0
while pos < SECTOR:
    ln = data[base+pos]
    if ln == 0: break
    ln, ext3, size3, name3, su3 = rec_info(data[base+pos:base+pos+ln])
    entries = []
    i = 0
    while i + 4 <= len(su3):
        sig = su3[i:i+2].decode('latin1'); l = su3[i+2]
        if l < 4: break
        entries.append((sig, su3[i+4:i+l].hex()))
        i += l
    print("DOCS entry", name3, "flags", data[base+pos+25], "size", size3, "entries", entries)
    pos += ln
