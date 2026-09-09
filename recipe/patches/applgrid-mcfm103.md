# APPLgrid bridge for MCFM 10.3

Fixed-order APPLgrid support for MCFM 10.x, ported from the 6.8 bridge.

Validated against MCFM 6.8 on E615 slice 0 (same `bridge.conf`, GRVPI1, two
passes):

| order | MCFM 6.8 | MCFM 10.3 | ratio   |
|-------|----------|-----------|---------|
| LO    | 72096    | 72195     | 1.00138 |
| NLO   | 92471    | 92652     | 1.00195 |

K-factors agree independently (1.283 both sides). Per-bin scatter is MC noise
with no systematic trend.

## How to build it

Tag `<version>-applgrid`, e.g. **`10.3-applgrid`**. `autoupload.yml` turns the
hyphen into a dot, so `PKG_VERSION` arrives as `10.3.applgrid`; `build.sh`
strips the `.applgrid` suffix to get the upstream MCFM version to download,
builds mcfm-bridge, passes `-Dwith_applgrid=ON`, and then **fails the build**
unless the resulting binary actually contains `appl::grid` symbols.

A plain `10.3` tag is unaffected: the same three MCFM patches are applied, but
`with_applgrid` stays OFF and `gridwrap.cxx`'s no-op stubs keep the default link
intact (verified -- see "gridwrap.cxx must be unconditional" below).

The bridge is mcfm-bridge **0.0.53**, the same tarball the 6.x branch fetches,
with the same two conf-driven patches plus `applgrid-bridge-mcfm103.patch`. All
three were verified to apply to 0.0.53 with `--fuzz=0`, and MCFM 10.3 linked
against that bridge produces the same grid as the 0.0.35-based build used for
the validation numbers above: 17 `appl::grid` symbols either way, and an LO grid
convoluting to ratio 1.00138 / worst bin 1.18% against MCFM 6.8 -- identical to
every digit. The 0.0.53 fill pass is markedly slower for the same output
(minutes vs ~30 s for E615 slice 0 at LO); unexplained, but it does not change
the numbers.

**The bridge is built with four explicit make targets, not a plain `make`.**
`src/Makefile.am` evaluates `LHAPDFPATH = $(shell lhapdf-config --pdfsets-path)`,
and modern LHAPDF renamed that option to `--datadir`, so `make` dies with
`Error: Unknown option '--pdfsets-path'` *after* `libmcfmbridge.a` has already
been archived. `libmcfmbridge.a`, `install-libLIBRARIES`, `mcfmbridge-config`
and `install-binSCRIPTS` are all MCFM needs and never touch that variable.
Note the 6.x branch still does a plain `make && make install` on the same
`Makefile.am` -- latent breakage there whenever the build image's LHAPDF is new
enough.

## Patches

| file | applies to | what it does |
|------|-----------|--------------|
| `applgrid-mcfm103-hooks.patch` | MCFM 10.3 | integrand hooks in lowint/virtint/realint/nplotter/mcfm_exit, plus new `src/Inc/APPLinclude.f` and `src/User/gridwrap.cxx`, and the `/gridnorm/` plumbing in parseinput.f90 / mod_MCFMStorage.f90 |
| `applgrid-mcfm103-hplog.patch` | MCFM 10.3 | renames `/fillred/` to `/mcfmfillred/` in hplog.f/hplog6.f; adds `hide-hplog.map` |
| `applgrid-mcfm103-cmake.patch` | MCFM 10.3 | `option(with_applgrid)`, bridge link flags, version script |
| `applgrid-bridge-mcfm103.patch` | mcfm-bridge **0.0.53** (on top of the two conf-driven patches) | repoints `grid->run()` at `/gridnorm/`; `__thread` on the commons 10.3 makes threadprivate |

All three MCFM patches were verified to apply to the pristine MCFM-10.3 tarball
with `--fuzz=0` and to reproduce the exact tree that produced the numbers above.

## Scope: fixed order only

The resummed (CuTe/SCET) contributions are deliberately not gridded. APPLgrid
stores PDF-stripped weights and re-convolves a PDF later, which is valid only
because a fixed-order cross section is LINEAR in the PDFs. Resummation is not:
its beam functions convolve PDFs with kernels at a b-space-dependent scale.
`contrib` is set only by the fixed-order integrands and stays 0 on any resummed
path, which is what gates the fill.

The same argument blocks NNLO below the slicing cut and N3LO entirely -- in 10.3
N3LO is grouped with `kresummed` in `pdfwrap_lhapdf.f` and requires
`resummation%makegrid` to tabulate transformed PDF sets. NLO grids plus
higher-order K-factors is the workable route.

## gridwrap.cxx must be unconditional

`src/User/gridwrap.cxx` is compiled for every 10.x build, not only when
`with_applgrid=ON`. It holds null-guarded no-op stubs for
`book_grid_`/`fill_grid_`/`write_grid_`, and `nplotter.f` / `mcfm_exit.f` call
those unconditionally -- the calls are compiled regardless of the runtime
`creategrid` test. An earlier revision of `applgrid-mcfm103-cmake.patch` gated
the file on the option, which broke the DEFAULT build:

    mcfm_exit.f: undefined reference to `write_grid_'
    nplotter.f:  undefined reference to `fill_grid_'

Verified after the fix: with the option OFF, cmake reports the bridge as not
enabled, the object is still compiled, and it defines all three symbols -- so
the default 10.x build links exactly as it did before these patches.

## Runtime requirements

1. **Two passes.** `book_grid()` branches on whether the grid file exists: pass
   1 creates and fills it, recording the populated phase space; pass 2 reads it
   back, resets the reference and calls `optimise()` before filling for real. A
   single pass gives a correct-looking *reference* histogram over unoptimised
   weight nodes, and a wrong convolution.
2. **`OMP_NUM_THREADS=1`.** The bridge is not thread-safe: `book_grid()` parses
   `appl_conf` into shared state (4 threads gave `bad edges (nbins=12
   edges=39)`) and `fill_grid()` mutates one shared `appl::grid`. Threadprivate
   commons were necessary but not sufficient.
3. **`ulimit -s unlimited`.** MCFM 10.3 asks OpenMP for 8389760 bytes of thread
   stack, just over the default 8192 KB, and aborts with `OMP: Error #29`.

## Notes that cost real time

- **10.3 never assigns `itmx` or `ncall`** -- `/bveg1int/` in vegas_common.f is
  vestigial. The 6.8 normalisation `/dfloat(itmx)` divides by zero and NaNs
  every stored weight. `/gridnorm/` (`ag_niter`, `ag_totcall`, `ag_fill`),
  populated from `integrate()`, replaces it. Members are doubles so there is no
  Fortran-integer-kind vs C-struct-padding ambiguity.
- **`ag_x1z`/`ag_x2z` must never be 0.** `x1onz`/`x2onz` are set only when
  `z > xx(1)`/`xx(2)`, and 10.3 builds with `-finit-local-zero`, so they are 0
  otherwise. The bridge passes them to APPLgrid as Bjorken x; x=0 is -infinity
  in log(x) and the grid allocates until the OOM killer fires (45 GB, against
  69 MB for the same run with `creategrid=.false.`).
- **alpha_s stripping**: `psCR = 1/ason2pi` applies unconditionally on the real
  and virtual paths. A wrong psCR is K-factor sized (~30%), which is what the
  NLO comparison rules out and the LO one cannot.
- **HPLOG**: libAPPLgrid both defines and *calls* `hplog_`/`fillred*hpl_`
  through the PLT and is not `-Bsymbolic`; with `-rdynamic` MCFM's copies won
  the lookup, so libAPPLgrid called MCFM's routines (filling `/mcfmfillred/`)
  and then read its own unfilled `fillred_`. `hide-hplog.map` marks those five
  `local:` so each side uses its own routines and its own common; verified to
  leave results bit-identical. An anonymous version script must not carry a
  `global: *;` clause after `local:` -- GNU ld rejects it.
- **Include order**: `realint.f` gets `maxd` from `ptilde.f`, so
  `APPLinclude.f` must follow that include and `maxd.f` must not be repeated;
  `lowint.f`/`virtint.f` include `maxd.f` themselves.

## Not ported

One virtint accumulation block: the `msqv+msq_cs(0..2)` colour-structure term.
In 10.3 that expression appears at two sites, guarded by `kcase==ktwojet` and by
`kW_2jet/kZ_2jet/kW_bjet/kZ_bjet/ktt_*/kbb_tot/kcc_tot`. Neither DY nor prompt
photon reaches it; it was skipped for anchor ambiguity, not absence. If a
W/Z+2jet grid is wanted, place it at both sites.
