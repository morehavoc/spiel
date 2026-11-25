# Writes the int8 encoder's weight.bin as a "segments" file: every byte that is NOT
# int8 weight data (file header, blob metadata, fp16 scales), with offsets. The app
# rebuilds a same-size weight.bin with zeros in the gaps (a sparse file on APFS).
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src,'rb').read()
count, _ = struct.unpack_from('<II', data, 0)
holes = []; pos = 64
for i in range(count):
    while struct.unpack_from('<I', data, pos)[0] != 0xDEADBEEF: pos += 64
    _, dtype, size, off = struct.unpack_from('<IIQQ', data, pos)
    if dtype in (3, 4): holes.append((off, off+size))
    pos = (off + size + 63)//64*64
keep = []; cur = 0
for a, b in holes:
    if a > cur: keep.append((cur, a))
    cur = b
if cur < len(data): keep.append((cur, len(data)))
with open(dst,'wb') as f:
    f.write(b'SPCN'); f.write(struct.pack('<QI', len(data), len(keep)))
    for a, b in keep:
        f.write(struct.pack('<QQ', a, b-a)); f.write(data[a:b])
print('total', len(data), 'kept segments', len(keep), 'kept bytes', sum(b-a for a,b in keep))
