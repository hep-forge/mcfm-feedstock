# gridwrap.cxx: stale `mxpart` and its impact on MCFM 6.8 grids

`src/User/gridwrap.cxx` is the C++ shim that gives MCFM's Fortran code
the `book_grid_`/`fill_grid_`/`write_grid_` symbols it calls when
`creategrid=.true.`, forwarding to whatever the APPLgrid bridge
(`mcfm-bridge`, `mcfm_interface.cxx`/`mcfm_grid.cxx`) has wired via
function pointers. It declares:

```cxx
static const int mxpart = 12;    // mcfm parameter : max number of partons in event record. defined in Inc/constants.f
void (*fill_gridptr)(const double evt[][mxpart])  = 0;
```

This `mxpart` is a hardcoded copy of MCFM's own `mxpart` parameter
(`src/Inc/constants.f`), needed because the C++ side has no way to read
a Fortran `parameter` at compile time. It has to match exactly.

**It doesn't.** MCFM bumped `mxpart` from 12 to 14 between 6.7 and 6.8.
`gridwrap.cxx` was never updated — this is true both in the pristine
MCFM 6.8 tarball from mcfm.fnal.gov *and* in hepforge's own
`mcfm-patch-0.0.8` (the official companion patch for 6.8). mcfm-bridge's
own `TODO` file acknowledges the 12-vs-14 change happened and that it
was only fixed on the bridge's own side (`mcfm_interface.cxx` does use
14) — not in `gridwrap.cxx`, which lives in MCFM's tree, not the
bridge's. As far as could be determined, nobody has actually fixed this
in the published sources.

## Impact if run against real MCFM 6.8 with the unpatched file

MCFM's momentum array is `p(mxpart,4)`. Fortran is column-major, so with
the real `mxpart=14` the memory layout is four contiguous blocks of 14
doubles: all-particle px, then py, then pz, then E (confirmed by
`mcfm_interface.cxx`'s own comment ordering: `evt[3]`=E, `evt[0]`=px,
`evt[1]`=py, `evt[2]`=pz). The C++ side computes `evt[a][b]` as
`base + a*STRIDE + b`; with `STRIDE=12` instead of 14:

- **No crash.** The underlying array is always allocated as `14*4`
  doubles regardless of what stride the C++ side assumes, so reads with
  the wrong stride stay in-bounds. There is no error, warning, or
  segfault to notice.
- **`a=0` (px) is unaffected** for every particle: offset `0*12+b`
  equals the true offset `0*14+b`.
- **`a=1,2,3` (py, pz, E) are read from the wrong offset** — each
  block is read starting 2 slots (times `a`) too early, so these values
  come from the tail of the previous component's block for the first
  couple of particle indices, then from the *wrong particle's* value
  for the rest.
- **The per-bin weight itself is unaffected.** It's passed through a
  separate common-block struct (`weightb`/`weightv`/`weightr` in
  `mcfm_grid.h`), not through the corrupted `evt` array.

Net effect: **the grid's total integrated cross section still matches
MCFM's own reported total** (weights are untouched), but **the
differential/kinematic binning is silently wrong** for every observable
that depends on py, pz, or E — i.e. essentially everything (pT needs
px & py, rapidity needs E & pz). A "does the grid reproduce MCFM's
total XS" sanity check — a very standard validation step — would not
catch this; only a shape comparison against a reference distribution
would.

**Who's affected:** only users who ran the unmodified `gridwrap.cxx`
(mxpart=12, correct for MCFM 6.7) against **MCFM 6.8** specifically.
MCFM 6.7 users were never affected — 12 was the right value there.

## The fix here

`applgrid-gridwrap-mxpart.patch` changes the constant to 14, applied
(via `build.sh`) after `applgrid-realint-virtint.patch` (hepforge's
official `mcfm-patch-0.0.8`) and before `gridwrap.f` is removed. This is
our own fix, not an upstream one — worth reporting back to hepforge
(applgrid.hepforge.org) since the inconsistency appears to still be
live in the current published sources.
