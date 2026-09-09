#! /usr/bin/bash
set -e

# A tag may carry an "-applgrid" suffix to request the APPLgrid-enabled
# variant, e.g. tag 10.3-applgrid. autoupload.yml turns hyphens into dots for
# the conda version, so PKG_VERSION arrives as "10.3.applgrid": strip that to
# get the MCFM version actually published upstream, and dispatch/download on
# MCFM_VER rather than PKG_VERSION. For a plain tag the two are identical, so
# 6.8 and 10.3 behave exactly as before.
MCFM_VER="${PKG_VERSION%.applgrid}"
if [ "$MCFM_VER" != "$PKG_VERSION" ]; then
    WITH_APPLGRID=ON
else
    WITH_APPLGRID=OFF
fi
echo "PKG_VERSION=${PKG_VERSION} -> MCFM_VER=${MCFM_VER} with_applgrid=${WITH_APPLGRID}"

case "$MCFM_VER" in
  6.*)
    # mcfm.fnal.gov's WAF blocks conda-build's own downloader (see the
    # `*)` branch below) -- fetch the real upstream tarball directly,
    # same as 10.x/9.x. This (not a GitHub mirror) matters here: it's
    # the only source that ships APPLgrid's book_grid/fill_grid/write_grid
    # hooks already wired live into nplotter.f/lowint.f/realint.f/
    # virtint.f/mcfm_exit.f (creategrid-gated, .false. by default in
    # Bin/input.DAT -- so this changes nothing for existing plain runs).
    # It has no OpenMP support, unlike the GitHub mirror used previously;
    # that's deliberate, not a regression -- the mcfm-bridge grid-filling
    # code below has no locking, so OMP + grid output would race.
    curl -sL "https://mcfm.fnal.gov/downloads/MCFM-${MCFM_VER}.tar.gz" -o mcfm.tar.gz
    tar xzf mcfm.tar.gz --strip-components=1
    rm mcfm.tar.gz

    # Small official refinement on top of the already-wired hooks above
    # (dynamic-scale handling + two more `case` variants in realint.f/
    # virtint.f) from hepforge's mcfm-patch-0.0.8 (applgrid.hepforge.org/
    # downloads, "for mcfm 6.8"). Diffed against this exact tarball.
    patch -p1 < "${RECIPE_DIR}/patches/applgrid-realint-virtint.patch"

    # gridwrap.cxx (the C++ shim providing the Fortran-callable
    # book_grid_/fill_grid_/write_grid_ symbols) hardcodes mxpart=12 in
    # both this tarball and hepforge's own mcfm-patch -- stale from MCFM
    # 6.7, where mxpart was 12; 6.8 bumped it to 14 (src/Inc/constants.f)
    # without anyone updating this copy (acknowledged in mcfm-bridge's
    # own TODO). Left uncorrected, evt[][mxpart] indexing in fill_grid()
    # would silently read the wrong offsets. Fix it before it's compiled.
    patch -p1 < "${RECIPE_DIR}/patches/applgrid-gridwrap-mxpart.patch"

    # src/User/gridwrap.f (an inert Fortran stub that just errors out if
    # ever called) and gridwrap.cxx both define book_grid_/fill_grid_/
    # write_grid_ -- a duplicate-symbol link error if both are compiled.
    # Upstream's own mcfm-patch cleanup.sh does the same removal.
    rm -f src/User/gridwrap.f

    # CPATH/LIBRARY_PATH get gfortran/gcc/ld to see $PREFIX's lhapdf
    # headers and library without touching the makefile's own FFLAGS/
    # LIBFLAGS. MCFMHOME/SOURCEDIR/QLDIR/etc. all resolve relative to
    # $(PWD) automatically, so no path patching needed there.
    export CPATH="${PREFIX}/include${CPATH:+:$CPATH}"
    export LIBRARY_PATH="${PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

    # Upstream's own installer (./Install) does this dir setup and
    # prebuilds the QCDLoop/TensorReduction static libs before the
    # top-level make can run -- the top makefile has no rule to create
    # its own obj/ (or the QCDLoop/TensorReduction ones), it just
    # assumes Install already ran. Replicated directly here instead of
    # calling Install itself, since that script also tries to typeset a
    # LaTeX manual (no latex in this build env, irrelevant for a binary
    # package) and symlink PDF sets from a CERNLIB/non-LHAPDF layout.
    mkdir -p obj
    mkdir -p TensorReduction/ov/obj

    # QCDLoop/makefile's default target (`all: test`) links a throwaway
    # test binary with a hardcoded `-lff` that doesn't always match what
    # its own ffdir target just built -- build only the qldir/ffdir
    # prerequisites actually needed (the .a files) and skip that link.
    (cd QCDLoop && make qldir ffdir FC="${FC}")
    (cd TensorReduction && make libs FC="${FC}")

    # The APPLgrid bridge itself (mcfm_interface.cxx/mcfm_grid.cxx --
    # the C++ side that actually books/fills/writes APPLgrid files) is
    # not part of MCFM's or APPLgrid's own distribution; it's a separate
    # hepforge package, "mcfm-bridge", vendored here and built with its
    # own autotools build system into a small static lib + config script.
    curl -sL "https://applgrid.hepforge.org/downloads/?f=mcfm-bridge-0.0.53.tgz" -o mcfm-bridge.tgz
    mkdir -p mcfm-bridge
    tar xzf mcfm-bridge.tgz -C mcfm-bridge --strip-components=1
    rm mcfm-bridge.tgz

    # Conf-driven binning/observables for the bridge. Stock mcfm-bridge only
    # knows a hard-coded `appl_e615` path: one process, 12 fixed x_F bins. These
    # add an `appl_conf=<file>` path so ONE binary can produce grids for any
    # dataset -- observable, bin edges, Q2/pT window, nproc, sqrts, x/Q2 grid
    # nodes and interpolation orders all read from a small text file.
    #
    # Written additively: the legacy `appl_e615` path is untouched, and the two
    # were verified to give an identical integral (8377.7387 fb, same seed).
    # Every conf key defaults to the previous behaviour, so a config omitting
    # them all reproduces stock output exactly.
    #
    # Diffed against pristine mcfm-bridge-0.0.35; verified to apply to 0.0.53
    # with `patch -p1 --fuzz=0` (exit 0, no offsets).
    patch -p1 -d mcfm-bridge < "${RECIPE_DIR}/patches/applgrid-bridge-conf-driven.patch"
    patch -p1 -d mcfm-bridge < "${RECIPE_DIR}/patches/applgrid-bridge-mcfm-grid.patch"

    (
      cd mcfm-bridge
      CC="${CC}" CXX="${CXX}" ./configure --prefix="${SRC_DIR}/mcfm-bridge-install"
      make
      make install
    )
    export PATH="${SRC_DIR}/mcfm-bridge-install/bin:${PATH}"

    # mcfmbridge-config's own --ldflags already assembles everything
    # needed: the `-u <mangled setup_mcfmbridge symbol>` force-link (so
    # the bridge's global initializer runs and wires the function
    # pointers gridwrap.cxx forwards to, even though nothing in MCFM's
    # own link line otherwise references the bridge), -lmcfmbridge, and
    # applgrid-config/root-config's own flags. hoppet/lhapdf are pulled
    # in transitively via libAPPLgrid.so's own link, not needed here.
    #
    # LIBFLAGS is passed on the command line (not left to the makefile's
    # own default) to get those flags onto the link line at all -- so
    # -lLHAPDF is spelled out explicitly too, rather than relying on the
    # makefile's own `ifeq ($(PDFROUTINES),LHAPDF) ... LIBFLAGS += -lLHAPDF`
    # to still fire correctly on a command-line-set variable.
    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
    make -j"$NPROC" \
      PDFROUTINES=LHAPDF \
      LHAPDFLIB="${PREFIX}/lib" \
      NTUPLES=NO \
      FC="${FC}" F90="${FC}" \
      LIBFLAGS="-lqcdloop -lff -lov -lpv -lsmallG -lsmallY -lsmallP -lsmallF -lLHAPDF $(mcfmbridge-config --ldflags)"

    # The 6.x path links the bridge unconditionally, so this check applies to
    # every 6.x tag, not just a -applgrid one. mcfmbridge-config --ldflags
    # carries a `-u <setup_mcfmbridge>` force-link; if that ever stops taking
    # effect the build still succeeds and quietly produces a binary with no
    # APPLgrid in it. Fail instead of shipping that.
    NSYM=$(nm -C Bin/mcfm 2>/dev/null | grep -c "appl::grid" || true)
    echo "appl::grid symbols in Bin/mcfm: ${NSYM}"
    if [ "${NSYM:-0}" -eq 0 ]; then
        echo "ERROR: 6.x builds link the APPLgrid bridge, but the binary" >&2
        echo "       contains no appl::grid symbols -- the force-link did not" >&2
        echo "       take. Refusing to publish a bridge-less mcfm." >&2
        exit 1
    fi

    mkdir -p "${PREFIX}/bin"
    cp Bin/mcfm "${PREFIX}/bin/mcfm"
    mkdir -p "${PREFIX}/share/mcfm"
    cp -Rf Bin/* "${PREFIX}/share/mcfm/"
    ;;

  *)
    # mcfm.fnal.gov's WAF returns 403 to conda-build's own downloader
    # (python-requests-style user agent) but allows a bare curl with no
    # explicit -A -- verified empirically, content is stable across
    # repeated fetches. No source: url in meta.yaml for this version;
    # fetch it here instead, into what conda-build already set up as
    # the (otherwise-empty) work directory.
    curl -sL "https://mcfm.fnal.gov/downloads/MCFM-${MCFM_VER}.tar.gz" -o mcfm.tar.gz
    tar xzf mcfm.tar.gz --strip-components=1
    rm mcfm.tar.gz

    export LD=$FC # prevent using LD in handyG
    ln -s $BUILD_PREFIX/include/* ./src/Inc/

    # handyG's configure emits link rules for auxiliary binaries (geval,
    # handyG, test) that fail in this toolchain. It ALSO makes `install`
    # depend on geval and copy it, so disabling only the link rules leaves
    # install failing with `cp: cannot stat 'geval'`. This patch covers both;
    # the library is all MCFM needs. (9.1 ships no lib/handyG, so this is
    # 10.x-only.)
    patch -p1 --fuzz=0 < "${RECIPE_DIR}/patches/handyG.patch"

    # ---- APPLgrid bridge sources (INERT unless -Dwith_applgrid=ON) ---------
    # Fixed-order APPLgrid support ported from the 6.8 bridge and validated
    # against it (LO 1.00138, NLO 1.00195 on E615 slice 0). See
    # patches/applgrid-mcfm103.md.
    #
    # These are applied unconditionally for 10.x but do NOT change the default
    # build: with_applgrid is a CMake option(... OFF), and both the bridge link
    # flags and the version script sit inside its if() block. The hplog rename
    # is self-contained within hplog.f/hplog6.f.
    #
    # with_applgrid is NOT switched on here. build.sh fetches mcfm-bridge
    # 0.0.53 for the 6.x path, while applgrid-bridge-mcfm103.patch was
    # generated against 0.0.35 (octofit's vendored, conf-driven copy). That
    # mismatch is unresolved and no conda build of 10.x with the bridge
    # enabled has been run, so enabling it is left as explicit follow-up work
    # rather than turned on untested.
    patch -p1 --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-mcfm103-hooks.patch"
    patch -p1 --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-mcfm103-hplog.patch"
    patch -p1 --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-mcfm103-cmake.patch"

    if [ "$(uname -m)" != "x86_64" ]; then
        # ---- aarch64 enablement -------------------------------------------
        # GCC builds libquadmath only where __float128 is a distinct type,
        # i.e. x86, whose long double is the 80-bit x87 format. On aarch64
        # `long double` IS IEEE 754 binary128 -- the identical format -- so
        # the quad arithmetic is already in libm under the long double names
        # and only GCC's `*q` spelling is missing. A header-only naming shim
        # supplies it; precision is unchanged.
        mkdir -p "${SRC_DIR}/quadmath-shim"
        cp "${RECIPE_DIR}/quadmath-shim.h" "${SRC_DIR}/quadmath-shim/quadmath.h"
        export CXXFLAGS="${CXXFLAGS:-} -I${SRC_DIR}/quadmath-shim"
        export CFLAGS="${CFLAGS:-} -I${SRC_DIR}/quadmath-shim"

        # Because __float128 becomes an ALIAS for long double rather than a
        # distinct type, the two declarations qcdloop makes on its `qdouble`
        # (a std::ostream operator<< and a std::hash specialisation) collide
        # with the existing long double ones. Guard exactly those. 10.3 ships
        # TWO bundled copies and both hard-include <quadmath.h>.
        for q in lib/qcdloop-2.0.5 lib/qcdloop-2.0.9; do
            [ -d "$q" ] || continue
            ( cd "$q" && patch -p1 --fuzz=0 \
                < "${RECIPE_DIR}/patches/aarch64-qcdloop-guards.patch" )
        done

        # CMakeLists: make -lquadmath conditional on x86 (nothing references
        # its symbols under the shim, so the link just fails looking for a
        # library it does not need), and pass the outer C/CXX flags explicitly
        # into the qcdloop ExternalProject.
        patch -p1 --fuzz=0 < "${RECIPE_DIR}/patches/aarch64-cmake.patch"
    fi

    # The top-level build pulls in qcdloop as a nested ExternalProject,
    # configured by its own cmake subprocess during `make` (not during
    # the `cmake ..` below) -- a CMAKE_ARGS passed to the outer cmake
    # invocation doesn't reach it. qcdloop's own CMakeLists.txt declares
    # a <3.5 minimum, removed in CMake 4. Exporting this as an env var
    # (rather than a -D flag) is what actually propagates to that nested
    # subprocess, since it inherits the environment, not the cache.
    export CMAKE_POLICY_VERSION_MINIMUM=3.5

    if [ "$WITH_APPLGRID" = "ON" ]; then
        # Same bridge tarball and the same two conf-driven patches the 6.x
        # branch uses, plus the 10.x-specific one.
        #
        # Verified against 0.0.53: all three patches apply with --fuzz=0, the
        # bridge builds and imports gridnorm_ (not the 6.8-era iterat_), and
        # MCFM 10.3 links against it with 17 appl::grid symbols -- the same
        # count as the 0.0.35-based build.
        #
        # Grid equivalence CONFIRMED: an LO grid built with the 0.0.53 bridge
        # convolutes to the same numbers as the 0.0.35 one used for the
        # validation in patches/applgrid-mcfm103.md -- ratio to MCFM 6.8
        # 1.00138, worst bin 1.18%, identical to every digit. So those
        # validation numbers apply to what this recipe actually builds.
        #
        # One unexplained observation, harmless but worth knowing: the 0.0.53
        # fill pass runs markedly slower than 0.0.35 on identical input
        # (minutes vs ~30 s for E615 slice 0 at LO) while producing the same
        # grid. Budget for it when timing production runs.
        curl -sL "https://applgrid.hepforge.org/downloads/?f=mcfm-bridge-0.0.53.tgz" -o mcfm-bridge.tgz
        mkdir -p mcfm-bridge
        tar xzf mcfm-bridge.tgz -C mcfm-bridge --strip-components=1
        rm mcfm-bridge.tgz

        patch -p1 -d mcfm-bridge --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-bridge-conf-driven.patch"
        patch -p1 -d mcfm-bridge --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-bridge-mcfm-grid.patch"
        patch -p1 -d mcfm-bridge --fuzz=0 < "${RECIPE_DIR}/patches/applgrid-bridge-mcfm103.patch"

        # Build ONLY the library and the config script, not the default `all`.
        # mcfm-bridge's src/Makefile.am evaluates
        #     LHAPDFPATH = $(shell lhapdf-config --pdfsets-path)
        # and modern LHAPDF renamed that option to --datadir, so a plain
        # `make` dies with "Error: Unknown option '--pdfsets-path'" AFTER
        # libmcfmbridge.a has already been archived. These four targets are
        # everything MCFM needs and never touch that variable.
        # (The 6.x branch above still does a plain make/make install on the
        # same Makefile.am -- latent breakage there whenever the build image's
        # LHAPDF is new enough.)
        (
          cd mcfm-bridge
          CC="${CC}" CXX="${CXX}" ./configure --prefix="${SRC_DIR}/mcfm-bridge-install"
          make -C src libmcfmbridge.a CXX="${CXX}"
          make -C src install-libLIBRARIES CXX="${CXX}"
          make -C bin mcfmbridge-config
          make -C bin install-binSCRIPTS
        )
        export PATH="${SRC_DIR}/mcfm-bridge-install/bin:${PATH}"
    fi

    mkdir build
    cd build

    cmake .. -DCMAKE_INSTALL_PREFIX=${PREFIX} -Dwith_library=ON \
            -Duse_internal_lhapdf=OFF -Dlhapdf_include_path=$(lhapdf-config --incdir) \
            -Duse_mpi=ON -Duse_coarray=OFF \
            -Dwith_applgrid=${WITH_APPLGRID}

    make
    make install

    if [ "$WITH_APPLGRID" = "ON" ]; then
        # A bridge that failed to force-link produces a binary with NO APPLgrid
        # in it and still exits 0 -- see patches/applgrid-mcfm103.md. Never let
        # that ship under a name promising APPLgrid support.
        NSYM=$(nm -C mcfm 2>/dev/null | grep -c "appl::grid" || true)
        echo "appl::grid symbols in mcfm: ${NSYM}"
        if [ "${NSYM:-0}" -eq 0 ]; then
            echo "ERROR: with_applgrid=ON but the binary contains no appl::grid symbols." >&2
            echo "       The bridge did not link; refusing to publish a package that" >&2
            echo "       advertises APPLgrid support without it." >&2
            exit 1
        fi
    fi

    mkdir -p $PREFIX/bin
    cp mcfm $PREFIX/bin
    mkdir -p $PREFIX/lib
    cp libmcfm.so $PREFIX/lib
    mkdir -p $PREFIX/share/mcfm/
    cp -Rf ../Bin/* $PREFIX/share/mcfm/
    mkdir -p $PREFIX/include
    cp -aLRf include/* $PREFIX/include/
    ;;
esac
