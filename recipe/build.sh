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

    # gfortran >= 10 makes argument-count/type mismatches hard errors, and
    # MCFM 6.8's bundled QCDLoop trips one immediately:
    #   QCDLoop/ff/ffxd0p.f: Error: Actual argument contains too few elements
    #   for dummy argument 'ipi12' (2/3)
    # Every 6.8 makefile hardcodes FFLAGS (QCDLoop: `FFLAGS = -g`), so adding
    # flags there is not enough -- wrap the compiler itself and hand the
    # wrapper to each make as FC, which build.sh already does for all of
    # them. Same flags as octofit's working local 6.8 build. (10.x does not
    # need this: its CMake adds -fallow-argument-mismatch itself.)
    # 6.8's last green recipe built from the HEPcodes GitHub mirror; this
    # only surfaced after switching to the official mcfm.fnal.gov tarball.
    cat > "${SRC_DIR}/fc-legacy" <<EOF
#!/bin/bash
exec "${FC}" -std=legacy -fallow-argument-mismatch -fallow-invalid-boz -w "\$@"
EOF
    chmod +x "${SRC_DIR}/fc-legacy"
    export FC="${SRC_DIR}/fc-legacy"

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

    # The makefile lists gridwrap.o in USERFILES but its `%.o: %.cxx` pattern
    # rule is commented out, so make has no way to build it:
    #   make: *** No rule to make target 'gridwrap.o', needed by 'mcfm'.
    # Compile the C++ shim by hand into obj/, where make finds it via VPATH --
    # exactly what octofit's working local 6.8 build does.
    mkdir -p obj
    "${CXX}" -c -O2 -fPIC -o obj/gridwrap.o src/User/gridwrap.cxx

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

    # Build ONLY the library and the config script, not the default `all`.
    # mcfm-bridge's src/Makefile.am evaluates
    #     LHAPDFPATH = $(shell lhapdf-config --pdfsets-path)
    # and LHAPDF renamed that option to --datadir, so a plain `make` dies with
    #     Error: Unknown option '--pdfsets-path'
    # AFTER libmcfmbridge.a has already been archived. These four targets are
    # everything MCFM needs and never touch that variable.
    #
    # This is why 6.8 went red: its last green build was 2026-07-04, and the
    # option disappeared from the build image's LHAPDF at some point after
    # that. Nothing in the recipe had to change for a working build to start
    # failing. Reproduced locally against LHAPDF 6.5.1, where the same plain
    # `make` fails identically and these targets succeed.
    (
      cd mcfm-bridge
      CC="${CC}" CXX="${CXX}" ./configure --prefix="${SRC_DIR}/mcfm-bridge-install"
      make -C src libmcfmbridge.a CXX="${CXX}"
      make -C src install-libLIBRARIES CXX="${CXX}"
      make -C bin mcfmbridge-config
      make -C bin install-binSCRIPTS
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
    # Use the host binutils name if plain `nm` is absent -- conda-build ships
    # ${HOST}-nm and plain nm is not guaranteed on PATH. If NEITHER exists,
    # warn and skip: a missing tool must not fail a build that is otherwise
    # fine. (An earlier revision exited 1 in that case, which turned a green
    # 6.8 red.)
    NM=$(command -v nm || command -v "${HOST}-nm" || command -v "${BUILD}-nm" || true)
    if [ -z "$NM" ]; then
        echo "WARNING: no nm found; skipping the appl::grid verification."
        NSYM=skip
    else
        NSYM=$("$NM" -C Bin/mcfm 2>/dev/null | grep -c "appl::grid" || true)
        echo "appl::grid symbols in Bin/mcfm: ${NSYM} (via $NM)"
    fi
    if [ "${NSYM}" != "skip" ] && [ "${NSYM:-0}" -eq 0 ]; then
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

    # macOS only: qd's autoconf config.sub (2012) predates Apple Silicon and
    # rejects the build triplet, failing the qd ExternalProject configure:
    #   configure: error: /bin/sh config/config.sub arm64-apple-darwin20.0.0 failed
    # Refresh it from conda-forge's gnuconfig. qd is the only autoconf project
    # in the 10.x tree. Linux builds are untouched.
    if [ "$(uname -s)" = "Darwin" ]; then
        for d in lib/qd-*/config; do
            cp "${BUILD_PREFIX}/share/gnuconfig/config.sub"   "$d/config.sub"
            cp "${BUILD_PREFIX}/share/gnuconfig/config.guess" "$d/config.guess"
        done
        # MCFM links only the static qd archives (qd_lib_static, qdmod_lib_static)
        # but configures qd with --enable-shared. macOS -dynamiclib requires
        # every symbol at link time, so libqdmod.dylib -- Fortran objects linked
        # by the C++ driver without -lgfortran -- fails:
        #   "__gfortran_transfer_character_write", referenced from ...qdmodule...
        # Build qd static-only on macOS; the shared library is never used.
        perl -pi -e 's/(--enable-fma --prefix=\S+) --enable-shared/$1 --disable-shared/' CMakeLists.txt
        # -F: the pattern contains ${...}, which BSD grep (macOS) reads as regex.
        grep -qF -- '--enable-fma --prefix=${CMAKE_BINARY_DIR}/local --disable-shared' CMakeLists.txt \
            || { echo "ERROR: could not switch qd to --disable-shared" >&2; exit 1; }
        # qcdloop's cache.cc derives its std::hash specializations from
        # libstdc++ internals (std::__hash_base, std::_Hash_impl) that libc++
        # lacks, so GCC on macOS (which uses libc++) rejects it. The patch swaps
        # in a portable byte hash; it is only a cache key.
        patch -p1 -d lib/qcdloop-2.0.9 < "${RECIPE_DIR}/patches/qcdloop-libcxx-hash.patch"
        # qcdloop finds libquadmath (QUADMATH_LIBRARY) but links nothing into
        # libqcdloop.dylib, which macOS rejects at link time:
        #   Undefined symbols for architecture arm64: "_cabsq", "_clogq", ...
        # (MCFM itself links only libqcdloop.a; this just lets the dylib build.)
        perl -pi -e 's/^target_link_libraries\(qcdloop_shared\)$/target_link_libraries(qcdloop_shared \${QUADMATH_LIBRARY})/' \
            lib/qcdloop-2.0.9/CMakeLists.txt
        grep -qF 'target_link_libraries(qcdloop_shared ${QUADMATH_LIBRARY})' lib/qcdloop-2.0.9/CMakeLists.txt \
            || { echo "ERROR: could not link quadmath into qcdloop_shared" >&2; exit 1; }
        # Compilers. MCFM's own C/C++ is built with CLANG: GCC 16 on darwin
        # compiles against libc++ with a different std::string layout than
        # the clang-built LHAPDF, so the PDF set name MCFM hands to
        # LHAPDF::mkPDF arrives garbled -- the package test aborted with
        #   LHAPDF::ReadError: Info file not found for PDF set ''
        # (reproduced standalone: GCC-built caller -> garbage name, clang ->
        # loads the set). GCC stays for Fortran and for qcdloop, which needs
        # __float128 (clang on arm64 has none); qcdloop's C++ API never
        # passes strings across to MCFM.
        MCFM_CC="${BUILD_PREFIX}/bin/${HOST}-clang"
        MCFM_CXX="${BUILD_PREFIX}/bin/${HOST}-clang++"
        QL_CC="${BUILD_PREFIX}/bin/${HOST}-gcc"
        QL_CXX="${BUILD_PREFIX}/bin/${HOST}-g++"
        for c in "$MCFM_CC" "$MCFM_CXX" "$QL_CC" "$QL_CXX"; do
            [ -x "$c" ] || { echo "ERROR: compiler $c not found" >&2; exit 1; }
        done
        export CC="$MCFM_CC" CXX="$MCFM_CXX"
        # MCFM only knows GNU/Intel C/C++ (FATAL_ERROR otherwise). C: Clang
        # takes the GNU branch (-fopenmp). C++: a Clang branch that adds
        # -femulated-tls as well -- gfortran on darwin stores threadprivate
        # COMMON blocks as GCC emulated TLS (___emutls_v.*), and MCFM's C++
        # reads them (see mcfm-cxxwrapper-clang-tls.patch below).
        perl -0pi -e 's/if \(CMAKE_CXX_COMPILER_ID STREQUAL "GNU"\)\n/if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")\n    set(CMAKE_CXX_FLAGS "\${CMAKE_CXX_FLAGS} -fopenmp -femulated-tls")\nelseif (CMAKE_CXX_COMPILER_ID STREQUAL "GNU")\n/' CMakeLists.txt
        perl -pi -e 's/if \(CMAKE_C_COMPILER_ID STREQUAL "GNU"\)/if (CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")/' CMakeLists.txt
        { grep -qF 'if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")' CMakeLists.txt \
            && grep -qF -- '-fopenmp -femulated-tls' CMakeLists.txt \
            && grep -qF 'if (CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")' CMakeLists.txt; } \
            || { echo "ERROR: could not let MCFM accept Clang" >&2; exit 1; }
        # The C++ side declares those COMMON blocks with `#pragma omp
        # threadprivate`, which clang compiles as C++ thread_local and reaches
        # through _ZTW wrapper routines nothing defines -- libmcfm.dylib failed
        # to link ("thread-local wrapper routine for qcdcouple_"). Declare them
        # __thread instead (no wrapper; with -femulated-tls, gfortran's storage).
        patch -p1 < "${RECIPE_DIR}/patches/mcfm-cxxwrapper-clang-tls.patch"
        # qcdloop inherits MCFM's C/C++ compilers; hand it GCC instead. The
        # paths go in through %ENV: interpolated into s///, their slashes
        # would end the regex.
        QL_CXX="$QL_CXX" QL_CC="$QL_CC" perl -pi -e 's/(ENABLE_FORTRAN_WRAPPER=ON .*)-DCMAKE_CXX_COMPILER=\$\{CMAKE_CXX_COMPILER\} -DCMAKE_C_COMPILER=\$\{CMAKE_C_COMPILER\}/$1-DCMAKE_CXX_COMPILER=$ENV{QL_CXX} -DCMAKE_C_COMPILER=$ENV{QL_CC}/' CMakeLists.txt
        grep -qF -- "-DCMAKE_CXX_COMPILER=${QL_CXX} -DCMAKE_C_COMPILER=${QL_CC}" CMakeLists.txt \
            || { echo "ERROR: could not point qcdloop at GCC" >&2; exit 1; }
        # MCFM hardcodes `stdc++` in its link lines; macOS has only libc++:
        #   ld: library not found for -lstdc++
        # And it links MPI (${MPI_Fortran_LIBRARIES}) into the mcfm executable
        # only, not into libmcfm, which a macOS dylib cannot leave unresolved:
        #   Undefined symbols: "_mpi_allreduce_", "_mpi_bcast_", ...
        # Add it to libmcfm's own link lines (empty when use_mpi is OFF). Not a
        # separate target_link_libraries(libmcfm ...) next to mcfm's: libmcfm
        # does not exist yet at that point in CMakeLists.txt.
        perl -pi -e 's/^(\s*target_link_libraries\(libmcfm .* quadmath) stdc\+\+/$1 c++ \${MPI_Fortran_LIBRARIES}/' CMakeLists.txt
        perl -pi -e 's/ quadmath stdc\+\+/ quadmath c++/g' CMakeLists.txt
        ! grep -qF -- 'quadmath stdc++' CMakeLists.txt \
            || { echo "ERROR: could not switch MCFM's link lines to libc++" >&2; exit 1; }
        [ "$(grep -cF -- 'quadmath c++ ${MPI_Fortran_LIBRARIES}' CMakeLists.txt)" = 2 ] \
            || { echo "ERROR: could not add MPI to both libmcfm link lines" >&2; exit 1; }
    fi
    ln -s $BUILD_PREFIX/include/* ./src/Inc/

    # mpi.mod is a gfortran module file, readable only by a gfortran writing
    # the same module version (see the mpich pin in conda_build_config.yaml).
    # Check it here, so a mismatch fails in seconds with a clear message
    # instead of ~40 min later at `use mpi` in mod_CPUTime.f90. Decompress
    # to files, not a pipe: `| head` could SIGPIPE gzip under set -e.
    if [ -f "${BUILD_PREFIX}/include/mpi.mod" ]; then
        modchk="${SRC_DIR}/modchk"; mkdir -p "$modchk"
        printf 'module mcfm_modchk\nend module mcfm_modchk\n' > "$modchk/t.f90"
        ( cd "$modchk" && "${FC}" -c t.f90 -o t.o )
        gzip -dc "$modchk/mcfm_modchk.mod"         > "$modchk/fc.txt"
        gzip -dc "${BUILD_PREFIX}/include/mpi.mod" > "$modchk/mpi.txt"
        fc_modv=$(sed -n "1s/.*module version '\([0-9]*\)'.*/\1/p" "$modchk/fc.txt")
        mpi_modv=$(sed -n "1s/.*module version '\([0-9]*\)'.*/\1/p" "$modchk/mpi.txt")
        echo "gfortran module version: FC=${fc_modv} mpi.mod=${mpi_modv}"
        if [ "${fc_modv}" != "${mpi_modv}" ]; then
            echo "ERROR: mpich's mpi.mod (module version ${mpi_modv}) cannot be read by" >&2
            echo "       ${FC} (module version ${fc_modv}). Pin an mpich build made with" >&2
            echo "       the same gfortran major (conda_build_config.yaml)." >&2
            exit 1
        fi
    fi

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

    # The quadmath shim is for LINUX aarch64 only, where long double IS IEEE
    # binary128. macOS arm64 also reports `uname -m` = arm64, but there long
    # double is plain 64-bit double (LDBL_MANT_DIG 53), so the shim would
    # #error -- and it is not needed: the GCC toolchain conda uses on macOS
    # supports __float128, and conda-forge's osx-arm64 libgcc ships
    # libquadmath.dylib. macOS therefore takes the same path as x86: real
    # libquadmath, pristine -lquadmath link, no shim and no aarch64 patches.
    if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" != "x86_64" ]; then
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

    # lhapdf include path from --prefix, NOT --incdir. conda-forge's
    # lhapdf-config (used on macOS, where hep-forge has no build) lists --incdir
    # in its help but does not implement it: it prints the whole help text,
    # which word-splits into cmake arguments and aborts configure with
    #   Argument "|" to --help did not match any keywords.
    # --prefix works for both hep-forge's and conda-forge's lhapdf.
    mkdir build
    cd build

    cmake .. -DCMAKE_INSTALL_PREFIX=${PREFIX} -Dwith_library=ON \
            -Duse_internal_lhapdf=OFF -Dlhapdf_include_path="$(lhapdf-config --prefix)/include" \
            -Duse_mpi=ON -Duse_coarray=OFF \
            -Dwith_applgrid=${WITH_APPLGRID}

    make
    make install

    if [ "$WITH_APPLGRID" = "ON" ]; then
        # A bridge that failed to force-link produces a binary with NO APPLgrid
        # in it and still exits 0 -- see patches/applgrid-mcfm103.md. Never let
        # that ship under a name promising APPLgrid support.
        NM=$(command -v nm || command -v "${HOST}-nm" || command -v "${BUILD}-nm" || true)
        if [ -z "$NM" ]; then
            echo "WARNING: no nm found; skipping the appl::grid verification."
            NSYM=skip
        else
            NSYM=$("$NM" -C mcfm 2>/dev/null | grep -c "appl::grid" || true)
            echo "appl::grid symbols in mcfm: ${NSYM} (via $NM)"
        fi
        if [ "${NSYM}" != "skip" ] && [ "${NSYM:-0}" -eq 0 ]; then
            echo "ERROR: with_applgrid=ON but the binary contains no appl::grid symbols." >&2
            echo "       The bridge did not link; refusing to publish a package that" >&2
            echo "       advertises APPLgrid support without it." >&2
            exit 1
        fi
    fi

    mkdir -p $PREFIX/bin
    cp mcfm $PREFIX/bin
    mkdir -p $PREFIX/lib
    # .dylib on macOS, .so on Linux
    cp libmcfm${SHLIB_EXT} $PREFIX/lib
    mkdir -p $PREFIX/share/mcfm/
    cp -Rf ../Bin/* $PREFIX/share/mcfm/
    mkdir -p $PREFIX/include
    cp -aLRf include/* $PREFIX/include/
    ;;
esac
