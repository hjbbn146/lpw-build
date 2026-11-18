"""列出 MOV 里 moov/meta 的全部 keys + ilst 值，以及各轨 summary。"""
import sys, struct

def bparse(buf, off, end):
    out = []
    while off + 8 <= end:
        sz, typ = struct.unpack('>I4s', buf[off:off+8]); hdr = 8
        if sz == 1:
            sz = struct.unpack('>Q', buf[off+8:off+16])[0]; hdr = 16
        elif sz == 0:
            sz = end - off
        if sz < hdr or off + sz > end:
            break
        out.append((typ.decode('latin1', 'replace'), off, sz, hdr))
        off += sz
    return out

def children(buf, box):
    typ, o, s, h = box
    start = o + h
    if typ == 'meta':
        # QuickTime 的 meta 是 fullbox，AVAssetWriter 写的不带 4 字节
        peek = buf[start:start+4]
        if peek in (b'\x00\x00\x00\x00',):
            start += 4
        else:
            # 判断：如果 start 处解析出的是合法 box（hdlr/keys/ilst），就不加
            t = bparse(buf, start, o + s)
            if not t or t[0][0] not in ('hdlr', 'keys', 'ilst'):
                start += 4
    elif typ == 'stsd':
        start += 8
    return bparse(buf, start, o + s)

def find(buf, box, path):
    cur = box
    for nm in path:
        got = None
        for c in children(buf, cur):
            if c[0] == nm:
                got = c; break
        if got is None:
            return None
        cur = got
    return cur

def payload(box):
    return box[1] + box[3]

def main(path):
    d = open(path, 'rb').read()
    print('='*70)
    print(path, len(d), 'bytes')
    top = bparse(d, 0, len(d))
    print('top boxes:', [(b[0], b[2]) for b in top])
    moov = [b for b in top if b[0] == 'moov'][0]
    traks = [c for c in children(d, moov) if c[0] == 'trak']
    print('traks:', len(traks))
    for i, tk in enumerate(traks):
        hd = find(d, tk, ['mdia', 'hdlr'])
        hn = d[payload(hd)+8:payload(hd)+12].decode('latin1', 'replace') if hd else '?'
        stsd = find(d, tk, ['mdia', 'minf', 'stbl', 'stsd'])
        fmt = '?'
        if stsd:
            P = payload(stsd)
            esz, etyp = struct.unpack('>I4s', d[P+8:P+16])
            fmt = etyp.decode('latin1', 'replace')
        tkhd = find(d, tk, ['tkhd'])
        tid = None
        if tkhd:
            P = payload(tkhd); v = d[P]
            tid = struct.unpack('>I', d[P+(12 if v == 0 else 20):][:4])[0]
        md = find(d, tk, ['mdia', 'mdhd'])
        ts = dur = None
        if md:
            P = payload(md); v = d[P]
            if v == 0:
                ts, dur = struct.unpack('>II', d[P+12:P+20])
            else:
                ts = struct.unpack('>I', d[P+20:P+24])[0]
                dur = struct.unpack('>Q', d[P+24:P+32])[0]
        stsz = find(d, tk, ['mdia', 'minf', 'stbl', 'stsz'])
        nsamp = 0
        if stsz:
            P = payload(stsz)
            fixed, cnt = struct.unpack('>II', d[P+4:P+12])
            nsamp = cnt
        print(f'  trak{i+1} id={tid} handler={hn} fmt={fmt} ts={ts} dur={dur} '
              f'({dur/ts if ts else 0:.3f}s) samples={nsamp}')
    # ---- meta 内容
    meta = None
    for c in children(d, moov):
        if c[0] == 'meta':
            meta = c
    if not meta:
        print('  (no moov/meta)')
        return
    print('  meta children:', [(c[0], c[2]) for c in children(d, meta)])
    keys = find(d, meta, ['keys'])
    keylist = []
    if keys:
        P = payload(keys)
        cnt = struct.unpack('>I', d[P+4:P+8])[0]
        q = P + 8
        for i in range(cnt):
            ksz, nsz = struct.unpack('>II', d[q:q+8])
            name = d[q+8:q+ksz].decode('utf-8', 'replace')
            keylist.append(name)
            print(f'    key[{i+1}] {name}')
            q += ksz
    ilst = find(d, meta, ['ilst'])
    if ilst:
        for c in children(d, ilst):
            idx = int(c[0].encode('latin1').hex(), 16) if c[0].strip('\x00') else 0
            # 4 字节 atom 名就是 key index
            ki = struct.unpack('>I', d[c[1]:c[1]+4])[0]
            name = keylist[ki-1] if 0 < ki <= len(keylist) else f'#{ki}'
            # 找 data box
            inner = bparse(d, c[1]+c[3], c[1]+c[2])
            val = '?'
            for ib in inner:
                if ib[0] == 'data':
                    P = payload(ib)
                    typ = struct.unpack('>I', d[P:P+4])[0] & 0xFFFFFF
                    raw = d[P+8:P+ib[2]-ib[3]]
                    if typ == 1:
                        val = raw.decode('utf-8', 'replace')
                    elif typ in (21, 22):
                        val = f'int={int.from_bytes(raw, "big", signed=True)}'
                    else:
                        val = f'type={typ} raw={raw.hex()[:60]}'
            print(f'    ilst {name} = {val}')

if __name__ == '__main__':
    for p in sys.argv[1:]:
        try:
            main(p)
        except Exception as e:
            print('ERR', p, e)
