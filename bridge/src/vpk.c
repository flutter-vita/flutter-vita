// See vpk.h. Three things, in order: the file I/O shim, the zip, the sfo and
// the package header.
#include "vpk.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

// ---------------------------------------------------------------- file I/O
//
// The console's sceIo and the host's POSIX, behind the same six calls.
// Whence values are the same on both (0 set, 1 current, 2 end).

#ifdef __vita__
#include <psp2/io/fcntl.h>
#include <psp2/io/stat.h>
typedef SceUID vfd;
static vfd io_open_r(const char* p) { return sceIoOpen(p, SCE_O_RDONLY, 0777); }
static vfd io_open_w(const char* p) {
  return sceIoOpen(p, SCE_O_WRONLY | SCE_O_CREAT | SCE_O_TRUNC, 0777);
}
static int io_read(vfd f, void* b, size_t n) { return sceIoRead(f, b, n); }
static int io_write(vfd f, const void* b, size_t n) { return sceIoWrite(f, b, n); }
static int64_t io_seek(vfd f, int64_t off, int whence) {
  return sceIoLseek(f, off, whence);
}
static void io_close(vfd f) { sceIoClose(f); }
static void io_mkdir(const char* p) { sceIoMkdir(p, 0777); }
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
typedef int vfd;
static vfd io_open_r(const char* p) { return open(p, O_RDONLY); }
static vfd io_open_w(const char* p) {
  return open(p, O_WRONLY | O_CREAT | O_TRUNC, 0644);
}
static int io_read(vfd f, void* b, size_t n) { return (int)read(f, b, n); }
static int io_write(vfd f, const void* b, size_t n) { return (int)write(f, b, n); }
static int64_t io_seek(vfd f, int64_t off, int whence) {
  return lseek(f, off, whence);
}
static void io_close(vfd f) { close(f); }
static void io_mkdir(const char* p) { mkdir(p, 0755); }
#endif

// Every directory on the way to `path`'s parent. Mkdir on one that exists
// fails and that is fine; the file open afterwards is the check.
static void mkdir_parents(char* path) {
  for (char* p = strchr(path + 1, '/'); p != NULL; p = strchr(p + 1, '/')) {
    *p = '\0';
    io_mkdir(path);
    *p = '/';
  }
}

// A whole small file, NUL-terminated for the callers that want a string.
static unsigned char* read_all(const char* path, size_t max, size_t* len) {
  const vfd f = io_open_r(path);
  if (f < 0) return NULL;
  const int64_t size = io_seek(f, 0, 2);
  io_seek(f, 0, 0);
  if (size < 0 || (size_t)size > max) {
    io_close(f);
    return NULL;
  }
  unsigned char* buf = malloc((size_t)size + 1);
  if (buf == NULL) {
    io_close(f);
    return NULL;
  }
  size_t got = 0;
  while (got < (size_t)size) {
    const int n = io_read(f, buf + got, (size_t)size - got);
    if (n <= 0) break;
    got += (size_t)n;
  }
  io_close(f);
  buf[got] = '\0';
  *len = got;
  return buf;
}

static int write_all(const char* path, const unsigned char* buf, size_t len) {
  char copy[256];
  snprintf(copy, sizeof copy, "%s", path);
  mkdir_parents(copy);
  const vfd f = io_open_w(path);
  if (f < 0) return -1;
  const int n = io_write(f, buf, len);
  io_close(f);
  return n == (int)len ? 0 : -1;
}

static void err_set(char* err, size_t cap, const char* fmt, ...) {
  if (err == NULL || cap == 0) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(err, cap, fmt, ap);
  va_end(ap);
}

// ---------------------------------------------------------------------- zip
//
// The central directory at the end of the file says where every entry's
// local header is and how big it is; the local header repeats the name and
// says where the bytes start. PKWARE's APPNOTE, sections 4.3.7 to 4.3.16.
// No zip64 -- a vpk is a few tens of megabytes -- and no encryption.

static uint16_t le16(const unsigned char* p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const unsigned char* p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 |
         (uint32_t)p[3] << 24;
}

enum { kInBuf = 64 * 1024, kOutBuf = 128 * 1024 };

typedef struct Entry {
  const char* name;  // not NUL-terminated; `name_len` long
  uint16_t name_len;
  uint16_t method;
  uint32_t crc;
  uint32_t csize;
  uint32_t usize;
  uint32_t local;  // offset of the local header
} Entry;

// Walks the central directory: fills `e` for the record at `*pos` and
// advances. Returns 0 at the end, 1 for an entry, -1 for a bad record.
static int next_entry(const unsigned char* cd, size_t cdlen, size_t* pos,
                      Entry* e) {
  if (*pos == cdlen) return 0;
  if (*pos + 46 > cdlen || le32(cd + *pos) != 0x02014b50u) return -1;
  const unsigned char* r = cd + *pos;
  e->method = le16(r + 10);
  e->crc = le32(r + 16);
  e->csize = le32(r + 20);
  e->usize = le32(r + 24);
  e->name_len = le16(r + 28);
  const uint16_t extra = le16(r + 30), comment = le16(r + 32);
  e->local = le32(r + 42);
  e->name = (const char*)r + 46;
  *pos += 46u + e->name_len + extra + comment;
  return *pos <= cdlen ? 1 : -1;
}

static int is_name(const Entry* e, const char* name) {
  const size_t n = strlen(name);
  return e->name_len == n && memcmp(e->name, name, n) == 0;
}

static int picked(const Entry* e) {
  if (e->name_len == 0 || e->name[e->name_len - 1] == '/') return 0;  // a directory
  return !is_name(e, "eboot2.bin") && !is_name(e, "sce_sys/param2.sfo");
}

// A name the archive chose is a path we are about to create under `root`.
// Refuse the ones that would leave it.
static int safe_name(const Entry* e) {
  if (e->name_len >= 200 || e->name[0] == '/') return 0;
  for (size_t i = 0; i < e->name_len; i++) {
    if (e->name[i] == '\\' || e->name[i] == ':' || e->name[i] == '\0') return 0;
    if (e->name[i] == '.' && i + 1 < e->name_len && e->name[i + 1] == '.' &&
        (i == 0 || e->name[i - 1] == '/') &&
        (i + 2 == e->name_len || e->name[i + 2] == '/')) {
      return 0;
    }
  }
  return 1;
}

// The central directory, read into memory. Returns NULL with `err` set.
static unsigned char* read_central(vfd f, size_t* cdlen, char* err, size_t errcap) {
  const int64_t size = io_seek(f, 0, 2);
  if (size < 22) {
    err_set(err, errcap, "not a zip (%lld bytes)", (long long)size);
    return NULL;
  }
  // The end record is 22 bytes plus a comment of up to 64 KB, and sits last.
  const size_t tail = size < 66 * 1024 ? (size_t)size : 66 * 1024;
  unsigned char* buf = malloc(tail);
  if (buf == NULL) {
    err_set(err, errcap, "out of memory");
    return NULL;
  }
  io_seek(f, size - (int64_t)tail, 0);
  size_t got = 0;
  while (got < tail) {
    const int n = io_read(f, buf + got, tail - got);
    if (n <= 0) break;
    got += (size_t)n;
  }
  long at = -1;
  for (long i = (long)got - 22; i >= 0; i--) {
    if (le32(buf + i) == 0x06054b50u) {
      at = i;
      break;
    }
  }
  if (at < 0) {
    free(buf);
    err_set(err, errcap, "no end-of-central-directory record");
    return NULL;
  }
  const uint16_t count = le16(buf + at + 10);
  const uint32_t cdsize = le32(buf + at + 12);
  const uint32_t cdoff = le32(buf + at + 16);
  free(buf);
  if (count == 0xFFFF || cdsize == 0xFFFFFFFFu || cdoff == 0xFFFFFFFFu) {
    err_set(err, errcap, "zip64 is not supported");
    return NULL;
  }
  if (cdsize > 4 * 1024 * 1024 || (int64_t)cdoff + cdsize > size) {
    err_set(err, errcap, "central directory out of range");
    return NULL;
  }
  unsigned char* cd = malloc(cdsize);
  if (cd == NULL) {
    err_set(err, errcap, "out of memory");
    return NULL;
  }
  io_seek(f, cdoff, 0);
  got = 0;
  while (got < cdsize) {
    const int n = io_read(f, cd + got, cdsize - got);
    if (n <= 0) break;
    got += (size_t)n;
  }
  if (got != cdsize) {
    free(cd);
    err_set(err, errcap, "short read of the central directory");
    return NULL;
  }
  *cdlen = cdsize;
  return cd;
}

typedef struct Extract {
  vfd in;
  unsigned char* ibuf;
  unsigned char* obuf;
  VpkProgress progress;
  void* ctx;
  uint64_t done;
  uint64_t total;
} Extract;

// One entry to `dest`. Progress every megabyte of output, for the eboot.
static int extract_one(Extract* x, const Entry* e, char* dest, char* err,
                       size_t errcap) {
  char name[208];
  snprintf(name, sizeof name, "%.*s", (int)e->name_len, e->name);

  unsigned char lh[30];
  io_seek(x->in, e->local, 0);
  if (io_read(x->in, lh, 30) != 30 || le32(lh) != 0x04034b50u) {
    err_set(err, errcap, "%s: bad local header", name);
    return -1;
  }
  const int64_t data = (int64_t)e->local + 30 + le16(lh + 26) + le16(lh + 28);
  io_seek(x->in, data, 0);

  mkdir_parents(dest);
  const vfd out = io_open_w(dest);
  if (out < 0) {
    err_set(err, errcap, "%s: cannot create %s", name, dest);
    return -1;
  }

  int rc = 0;
  uint32_t crc = crc32(0L, Z_NULL, 0);
  uint64_t written = 0, since_report = 0;
  uint32_t left = e->csize;
  z_stream z;
  memset(&z, 0, sizeof z);
  const int deflated = e->method == 8;
  if (deflated && inflateInit2(&z, -MAX_WBITS) != Z_OK) {
    io_close(out);
    err_set(err, errcap, "%s: inflateInit2 failed", name);
    return -1;
  }
  if (!deflated && e->method != 0) {
    io_close(out);
    err_set(err, errcap, "%s: compression method %u", name, e->method);
    return -1;
  }

  for (;;) {
    if (z.avail_in == 0 && left > 0) {
      const size_t want = left < kInBuf ? left : kInBuf;
      const int n = io_read(x->in, x->ibuf, want);
      if (n <= 0) {
        err_set(err, errcap, "%s: short read", name);
        rc = -1;
        break;
      }
      z.next_in = x->ibuf;
      z.avail_in = (uInt)n;
      left -= (uint32_t)n;
    }
    size_t chunk;
    int end = 0;
    if (deflated) {
      z.next_out = x->obuf;
      z.avail_out = kOutBuf;
      const int r = inflate(&z, Z_NO_FLUSH);
      if (r != Z_OK && r != Z_STREAM_END) {
        err_set(err, errcap, "%s: inflate %d", name, r);
        rc = -1;
        break;
      }
      chunk = kOutBuf - z.avail_out;
      end = r == Z_STREAM_END;
    } else {
      chunk = z.avail_in;
      memcpy(x->obuf, z.next_in, chunk);
      z.avail_in = 0;
      end = left == 0;
    }
    if (chunk > 0) {
      if (io_write(out, x->obuf, chunk) != (int)chunk) {
        err_set(err, errcap, "%s: write failed (card full?)", name);
        rc = -1;
        break;
      }
      crc = crc32(crc, x->obuf, (uInt)chunk);
      written += chunk;
      x->done += chunk;
      since_report += chunk;
      if (since_report >= 1024 * 1024 && x->progress != NULL) {
        since_report = 0;
        x->progress(x->ctx, name, x->done, x->total);
      }
    }
    if (end) break;
    if (deflated && chunk == 0 && z.avail_in == 0 && left == 0) {
      err_set(err, errcap, "%s: truncated", name);
      rc = -1;
      break;
    }
  }
  if (deflated) inflateEnd(&z);
  io_close(out);
  if (rc == 0 && (written != e->usize || crc != e->crc)) {
    err_set(err, errcap, "%s: %s", name,
            written != e->usize ? "size mismatch" : "crc mismatch");
    rc = -1;
  }
  return rc;
}

int vpk_extract(const char* vpk, const char* root, VpkProgress progress,
                void* ctx, char* err, size_t errcap) {
  if (err != NULL && errcap) err[0] = '\0';
  Extract x;
  memset(&x, 0, sizeof x);
  x.progress = progress;
  x.ctx = ctx;
  x.in = io_open_r(vpk);
  if (x.in < 0) {
    err_set(err, errcap, "cannot open %s", vpk);
    return -1;
  }
  size_t cdlen = 0;
  unsigned char* cd = read_central(x.in, &cdlen, err, errcap);
  if (cd == NULL) {
    io_close(x.in);
    return -1;
  }
  int rc = 0;
  Entry e;
  size_t pos = 0;
  int r;
  while ((r = next_entry(cd, cdlen, &pos, &e)) == 1) {
    if (picked(&e)) x.total += e.usize;
  }
  if (r < 0) {
    err_set(err, errcap, "bad central directory");
    rc = -1;
  }
  x.ibuf = malloc(kInBuf);
  x.obuf = malloc(kOutBuf);
  if (rc == 0 && (x.ibuf == NULL || x.obuf == NULL)) {
    err_set(err, errcap, "out of memory");
    rc = -1;
  }
  pos = 0;
  while (rc == 0 && next_entry(cd, cdlen, &pos, &e) == 1) {
    if (!picked(&e)) continue;
    if (!safe_name(&e)) {
      err_set(err, errcap, "refusing entry name %.*s", (int)e.name_len, e.name);
      rc = -1;
      break;
    }
    char dest[256];
    snprintf(dest, sizeof dest, "%s/%.*s", root, (int)e.name_len, e.name);
    if (progress != NULL) {
      char name[208];
      snprintf(name, sizeof name, "%.*s", (int)e.name_len, e.name);
      progress(ctx, name, x.done, x.total);
    }
    rc = extract_one(&x, &e, dest, err, errcap);
  }
  free(x.ibuf);
  free(x.obuf);
  free(cd);
  io_close(x.in);
  return rc;
}

// ---------------------------------------------------------------------- sfo
//
// "\0PSF", then at 0x08 the key table offset, 0x0C the data table offset,
// 0x10 the entry count, and from 0x14 sixteen-byte entries: key offset (u16),
// format (u16), length, capacity, data offset. Keys are NUL-terminated
// strings in the key table; TITLE_ID is a UTF-8 string in the data table.

int vpk_title_id(const char* sfo, char* out, size_t cap) {
  size_t len = 0;
  unsigned char* b = read_all(sfo, 64 * 1024, &len);
  if (b == NULL) return -1;
  int rc = -1;
  if (len >= 20 && memcmp(b, "\0PSF", 4) == 0) {
    const uint32_t keys = le32(b + 8), data = le32(b + 12), count = le32(b + 16);
    for (uint32_t i = 0; i < count && 20 + i * 16 + 16 <= len; i++) {
      const unsigned char* e = b + 20 + i * 16;
      const uint32_t koff = keys + le16(e), dlen = le32(e + 4), doff = data + le32(e + 12);
      if (koff + 9 > len || doff + dlen > len) continue;
      if (memcmp(b + koff, "TITLE_ID", 9) != 0) continue;
      // Nine characters, four letters and five digits; a trailing NUL is
      // counted in dlen by some writers and not by others.
      const char* v = (const char*)b + doff;
      size_t n = 0;
      while (n < dlen && v[n] != '\0') n++;
      if (n != 9 || cap < 10) break;
      int ok = 1;
      for (size_t k = 0; k < 9; k++) {
        const char c = v[k];
        ok &= k < 4 ? (c >= 'A' && c <= 'Z') : (c >= '0' && c <= '9');
      }
      if (!ok) break;
      memcpy(out, v, 9);
      out[9] = '\0';
      rc = 0;
      break;
    }
  }
  free(b);
  return rc;
}

// ------------------------------------------------------------------- head.bin

// SHA-1, FIPS 180-4. Forty lines because the engine archive exports no
// hashing symbol and the console's own is behind a module nobody has loaded
// from a user process.
typedef struct Sha1 {
  uint32_t h[5];
  uint64_t bits;
  unsigned char block[64];
  size_t fill;
} Sha1;

static uint32_t rol(uint32_t v, int n) { return v << n | v >> (32 - n); }

static void sha1_block(Sha1* s, const unsigned char* p) {
  uint32_t w[80];
  for (int i = 0; i < 16; i++) {
    w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 |
           (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
  }
  for (int i = 16; i < 80; i++) w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
  uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3], e = s->h[4];
  for (int i = 0; i < 80; i++) {
    uint32_t f, k;
    if (i < 20) { f = (b & c) | (~b & d); k = 0x5A827999u; }
    else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1u; }
    else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCu; }
    else { f = b ^ c ^ d; k = 0xCA62C1D6u; }
    const uint32_t t = rol(a, 5) + f + e + k + w[i];
    e = d; d = c; c = rol(b, 30); b = a; a = t;
  }
  s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e;
}

static void sha1_init(Sha1* s) {
  s->h[0] = 0x67452301u; s->h[1] = 0xEFCDAB89u; s->h[2] = 0x98BADCFEu;
  s->h[3] = 0x10325476u; s->h[4] = 0xC3D2E1F0u;
  s->bits = 0;
  s->fill = 0;
}

static void sha1_update(Sha1* s, const unsigned char* p, size_t n) {
  s->bits += (uint64_t)n * 8;
  while (n > 0) {
    const size_t take = 64 - s->fill < n ? 64 - s->fill : n;
    memcpy(s->block + s->fill, p, take);
    s->fill += take;
    p += take;
    n -= take;
    if (s->fill == 64) {
      sha1_block(s, s->block);
      s->fill = 0;
    }
  }
}

static void sha1_final(Sha1* s, unsigned char out[20]) {
  const uint64_t bits = s->bits;
  const unsigned char one = 0x80, zero = 0;
  sha1_update(s, &one, 1);
  while (s->fill != 56) sha1_update(s, &zero, 1);
  unsigned char len[8];
  for (int i = 0; i < 8; i++) len[i] = (unsigned char)(bits >> (56 - i * 8));
  sha1_update(s, len, 8);
  for (int i = 0; i < 5; i++) {
    out[i * 4] = (unsigned char)(s->h[i] >> 24);
    out[i * 4 + 1] = (unsigned char)(s->h[i] >> 16);
    out[i * 4 + 2] = (unsigned char)(s->h[i] >> 8);
    out[i * 4 + 3] = (unsigned char)s->h[i];
  }
}

static void sha1(const unsigned char* p, size_t n, unsigned char out[20]) {
  Sha1 s;
  sha1_init(&s);
  sha1_update(&s, p, n);
  sha1_final(&s, out);
}

// The keyless digest of make-head-bin.dart: SHA-1 of the region, a fixed
// rearrangement of those twenty bytes into a 64-byte block, SHA-1 of that,
// first sixteen bytes. The console computes the same function over the same
// public bytes; there is no secret in it.
static void fpkg_digest(const unsigned char* p, size_t n, unsigned char out[16]) {
  unsigned char a[20], b[20], buf[64];
  sha1(p, n, a);
  memset(buf, 0, sizeof buf);
  memcpy(buf, a + 4, 8);
  memcpy(buf + 8, a + 4, 8);
  memcpy(buf + 16, a + 12, 4);
  buf[20] = a[16];
  buf[21] = a[1];
  buf[22] = a[2];
  buf[23] = a[3];
  memcpy(buf + 24, buf + 16, 8);
  sha1(buf, sizeof buf, b);
  memcpy(out, b, 16);
}

static uint32_t be32(const unsigned char* p) {
  return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

int vpk_write_head(const char* tmpl, const char* dst, const char* titleid,
                   char* err, size_t errcap) {
  if (err != NULL && errcap) err[0] = '\0';
  if (strlen(titleid) != 9) {
    err_set(err, errcap, "title id is not nine characters");
    return -1;
  }
  size_t len = 0;
  unsigned char* h = read_all(tmpl, 64 * 1024, &len);
  if (h == NULL) {
    err_set(err, errcap, "cannot read %s", tmpl);
    return -1;
  }
  if (len < 0xF0 || memcmp(h, "\x7fPKG", 4) != 0) {
    free(h);
    err_set(err, errcap, "%s is not a package header", tmpl);
    return -1;
  }
  // Three regions, digested in this order: each digest covers bytes an
  // earlier one may have written.
  const uint32_t hdr_len = be32(h + 0xD0);
  const uint32_t info_off = be32(h + 0x08), info_len = be32(h + 0x10);
  const uint32_t info_out = be32(h + 0xD4);
  const uint32_t all_len = be32(h + 0xE8);
  if ((uint64_t)hdr_len + 16 > len || info_len < 64 ||
      (uint64_t)info_off + info_len > len || (uint64_t)info_out + 16 > len ||
      (uint64_t)all_len + 16 > len) {
    free(h);
    err_set(err, errcap, "%s: digest offsets out of range", tmpl);
    return -1;
  }
  char cid[48];
  memset(cid, 0, sizeof cid);
  snprintf(cid, sizeof cid, "EP9000-%s_00-0000000000000000", titleid);
  memcpy(h + 0x30, cid, sizeof cid);
  fpkg_digest(h, hdr_len, h + hdr_len);
  fpkg_digest(h + info_off, info_len - 64, h + info_out);
  fpkg_digest(h, all_len, h + all_len);
  const int rc = write_all(dst, h, len);
  free(h);
  if (rc < 0) err_set(err, errcap, "cannot write %s", dst);
  return rc;
}
