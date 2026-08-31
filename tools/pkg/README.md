# head-template.bin

The package header `scePromoterUtilityPromotePkgWithRif` requires, with four
fields rewritten per install by [`../make-head-bin.py`](../make-head-bin.py):
the content id at `0x30` and three digests whose offsets the header itself
carries.

**This file came off this console**, copied from
`ux0:app/FVTA00002/sce_sys/package/head.bin` after an ordinary install. The
promoter wrote it. It is not VitaShell's embedded resource, which is GPLv3
against this repo's BSD-3-Clause, and none of that project's code or data is
here. The format was read from their source as fact -- byte offsets and a
digest algorithm -- and implemented independently.

Its content id still says `FVTA00002` because nothing rewrites the template in
place; every install starts from these bytes and patches a copy.

`work.bin` sits beside `head.bin` in an installed app and is byte-identical
across titles, so it looked like it belonged here too. It does not: the
successful promote on 2026-08-31 staged `eboot.bin`, `sce_sys/param.sfo` and
`sce_sys/package/head.bin` and nothing else. The promoter writes `work.bin`
itself.
