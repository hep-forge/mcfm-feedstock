# applgrid-bridge-conf-driven.patch

Applies to **mcfm-bridge** `src/mcfm_interface.cxx` (6.x APPLgrid path).

## What it does

Stock mcfm-bridge books grids from a hard-coded path guarded by the `appl_e615`
environment variable: a single process with 12 fixed x_F bin edges compiled into
the source. Producing a grid for any other dataset means editing C++ and
rebuilding.

This adds a parallel conf-driven path, selected by `appl_conf=<file>`, that reads
the whole grid definition from a small text file:

| key | meaning |
|---|---|
| `observable` | `xF` or `pT` |
| `nbins`, `edges` | observable binning (the experiment's own bin edges) |
| `q2lo`, `q2hi` | Q^2 window |
| `ptlo`, `pthi` | optional pT slice cut |
| `nproc`, `sqrts` | MCFM process id and beam energy |
| `xlow`, `xup`, `nxbins`, `xorder` | x-grid nodes and interpolation order |
| `nq2bins`, `qorder` | Q^2-grid nodes and interpolation order |
| `basename` | output grid name |
| `genpdf` | channel decomposition config (default `basic`) |
| `gridsuffix` | output filename suffix |
| `obsparticle` | final-state particles summed for x_F, as a digit string (`3`, `34`, `345`) |
| `cutparticle` | particle used for the pT-window cut |

## Why it is safe

Written **additively**. The legacy `appl_e615` path is untouched and still
selected by its own environment variable. The two were verified to produce an
identical integral (8377.7387 fb) on the same seed.

Every conf key defaults to the previous hard-coded behaviour, so a conf file that
omits all of them reproduces stock output exactly. `obsparticle` in particular
defaults to the old `nproc >= 280 && nproc <= 286` test for deciding whether x_F
is the photon's or the dilepton pair's.

## Provenance

Diffed against pristine `mcfm-bridge-0.0.35`
(sha256 `132e15258255f063d8fc2d8e7f04b77eb6182a31b836faa7840c9df67d3b711e`,
https://applgrid.hepforge.org/downloads/mcfm-bridge-0.0.35.tgz).

Verified to apply to the 0.0.53 tarball this recipe fetches with
`patch -p1 --fuzz=0` — exit 0, no offsets, no fuzz.

## Verifying a build picked it up

The four newer keys are string literals, so they show in the binary:

```sh
strings $PREFIX/bin/mcfm | grep -E '^(genpdf|gridsuffix|obsparticle|cutparticle)$'
```

All four should print. If none do, the bridge was not rebuilt — note that
mcfm-bridge's own `build.sh` skips the entire bridge step when
`local/bin/mcfmbridge-config` already exists.
