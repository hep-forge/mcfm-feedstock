#! /usr/bin/bash
set -e

case "$PKG_VERSION" in
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
    curl -sL "https://mcfm.fnal.gov/downloads/MCFM-${PKG_VERSION}.tar.gz" -o mcfm.tar.gz
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
    curl -sL "https://mcfm.fnal.gov/downloads/MCFM-${PKG_VERSION}.tar.gz" -o mcfm.tar.gz
    tar xzf mcfm.tar.gz --strip-components=1
    rm mcfm.tar.gz

    export LD=$FC # prevent using LD in handyG
    ln -s $BUILD_PREFIX/include/* ./src/Inc/

    # The top-level build pulls in qcdloop as a nested ExternalProject,
    # configured by its own cmake subprocess during `make` (not during
    # the `cmake ..` below) -- a CMAKE_ARGS passed to the outer cmake
    # invocation doesn't reach it. qcdloop's own CMakeLists.txt declares
    # a <3.5 minimum, removed in CMake 4. Exporting this as an env var
    # (rather than a -D flag) is what actually propagates to that nested
    # subprocess, since it inherits the environment, not the cache.
    export CMAKE_POLICY_VERSION_MINIMUM=3.5

    mkdir build
    cd build

    cmake .. -DCMAKE_INSTALL_PREFIX=${PREFIX} -Dwith_library=ON \
            -Duse_internal_lhapdf=OFF -Dlhapdf_include_path=$(lhapdf-config --incdir) \
            -Duse_mpi=ON -Duse_coarray=OFF

    make
    make install

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
