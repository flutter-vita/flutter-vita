// Reading a .vpk on the console: the parts of an install that are only bytes.
//
// A vpk is a zip. Installing one is what tools/install-vpk.sh does from the
// host -- unzip, generate sce_sys/package/head.bin for the title id in
// sce_sys/param.sfo, stage under ux0:data/pkg, promote -- and this file is
// the first three of those steps in C, so the receiver's FILES tab can do it
// from a vpk already on the card. No receiver state in here: the caller owns
// the staging directory, the promoter and the log, and hears about progress
// through a callback.
//
// Built for the host too (tools/test-vpk.sh compiles it with the system
// zlib and checks it against unzip and make-head-bin.py), which is why the
// file I/O sits behind six small functions.
#ifndef FVITA_VPK_H
#define FVITA_VPK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Which entries of the zip to take.
//
//   VPK_STAGE   everything the promoter should see: not the LiveArea art
//               (icon0.png and sce_sys/livearea/, which the promoter
//               validates and refuses with 0x8010113D when not 8-bit
//               indexed) and not the supervisor pair (eboot2.bin and
//               sce_sys/param2.sfo, refused with 0x80101104).
//   VPK_ART     only the art, for ux0:app/<id> after the promote.
typedef enum { VPK_STAGE, VPK_ART } VpkPick;

// Before each entry, and about every megabyte inside one. `done` and `total`
// are bytes of the picked entries once unpacked.
typedef void (*VpkProgress)(void* ctx, const char* name, uint64_t done,
                            uint64_t total);

// Unpack the picked entries of `vpk` under `root`, creating directories on
// the way. Returns 0, or a negative number with `err` saying which entry and
// why. Stored and deflated entries only, which is every vpk this tree builds;
// an entry whose CRC does not match is an error, not a warning.
int vpk_extract(const char* vpk, const char* root, VpkPick pick,
                VpkProgress progress, void* ctx, char* err, size_t errcap);

// TITLE_ID out of a param.sfo, nine upper-case characters. Returns 0 when it
// is there and well-formed.
int vpk_title_id(const char* sfo, char* out, size_t cap);

// Write the package header the promoter wants for `titleid` at `dst`,
// from the header at `tmpl`: any head.bin the promoter itself wrote will do,
// this receiver's own app0:sce_sys/package/head.bin included. Rewrites the
// content id at 0x30 and the three keyless digests whose offsets the header
// carries (tools/make-head-bin.py describes the format and where the
// template came from). Returns 0, or a negative number with `err` filled.
int vpk_write_head(const char* tmpl, const char* dst, const char* titleid,
                   char* err, size_t errcap);

#ifdef __cplusplus
}
#endif

#endif
