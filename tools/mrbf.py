"""用心读书备份包：读取 customSite、回写（删除指定行）。
只替换 zip 的 sql.mrbf 条目，其余条目的压缩数据原样拷贝（不解压、不重压）。"""
import zipfile, struct, sqlite3, json, os, shutil, tempfile, zlib

SQL = 'sql.mrbf'

def read_sites(zpath):
    z = zipfile.ZipFile(zpath)
    tmp = tempfile.mkdtemp()
    p = os.path.join(tmp, SQL)
    open(p, 'wb').write(z.read(SQL))
    c = sqlite3.connect(p)
    rows = c.execute('select id,siteIdent,siteName,url,xpath from customSite order by "index",id').fetchall()
    c.close(); shutil.rmtree(tmp, ignore_errors=True)
    return rows

def rewrite(zpath, out, delete_ids):
    """删除 customSite 中 id 在 delete_ids 的行；其余条目原样保留。"""
    zi = zipfile.ZipFile(zpath)
    tmp = tempfile.mkdtemp(); p = os.path.join(tmp, SQL)
    open(p, 'wb').write(zi.read(SQL))
    c = sqlite3.connect(p)
    c.execute('pragma journal_mode=delete')
    c.executemany('delete from customSite where id=?', [(i,) for i in delete_ids])
    c.commit(); c.execute('vacuum'); c.close()
    new = open(p, 'rb').read(); shutil.rmtree(tmp, ignore_errors=True)
    # 原样拷贝其他条目：直接复制压缩字节
    src = open(zpath, 'rb')
    with open(out, 'wb') as o:
        cd = []
        for info in zi.infolist():
            off = o.tell()
            if info.filename == SQL:
                data = new
                comp = zlib.compressobj(6, zlib.DEFLATED, -15); cdata = comp.compress(data) + comp.flush()
                crc = zlib.crc32(data) & 0xffffffff
                fnb = info.filename.encode('utf-8')
                flag = 0x800
                hdr = struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, flag, 8, info.date_time[3] << 11 | info.date_time[4] << 5 | info.date_time[5] // 2,
                                  (info.date_time[0] - 1980) << 9 | info.date_time[1] << 5 | info.date_time[2], crc, len(cdata), len(data), len(fnb), 0)
                o.write(hdr + fnb + cdata)
                cd.append((info, fnb, crc, len(cdata), len(data), off, flag, 8))
            else:
                src.seek(info.header_offset)
                h = src.read(30)
                _, _, fl, meth, mt, md, crc, cs, us, fnl, exl = struct.unpack('<IHHHHHIIIHH', h[:30])
                fn = src.read(fnl); ex = src.read(exl)
                body = src.read(cs)
                o.write(struct.pack('<IHHHHHIIIHH', 0x04034b50, 20, fl, meth, mt, md, crc, cs, us, fnl, 0) + fn + body)
                cd.append((info, fn, crc, cs, us, off, fl, meth))
        cstart = o.tell()
        for info, fn, crc, cs, us, off, fl, meth in cd:
            dt = info.date_time
            o.write(struct.pack('<IHHHHHHIIIHHHHHII', 0x02014b50, 20, 20, fl, meth, dt[3] << 11 | dt[4] << 5 | dt[5] // 2,
                                (dt[0] - 1980) << 9 | dt[1] << 5 | dt[2], crc, cs, us, len(fn), 0, 0, 0, 0, info.external_attr, off) + fn)
        cend = o.tell()
        o.write(struct.pack('<IHHHHIIH', 0x06054b50, 0, 0, len(cd), len(cd), cend - cstart, cstart, 0))
    return out
