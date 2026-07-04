#! /usr/bin/bash
set -e

case "$PKG_VERSION" in
  6.*)
    # HEPcodes/MCFM (git_url in meta.yaml) already checked out into
    # $SRC_DIR by conda-build. Classic hand-maintained Makefile, not
    # CMake: MCFMHOME/SOURCEDIR/QLDIR/etc. all resolve relative to
    # $(PWD) automatically, so no path patching needed there. CPATH/
    # LIBRARY_PATH get gfortran/gcc/ld to see $PREFIX's lhapdf headers
    # and library without touching the makefile's own FFLAGS/LIBFLAGS.
    export CPATH="${PREFIX}/include${CPATH:+:$CPATH}"
    export LIBRARY_PATH="${PREFIX}/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

    # Upstream's own installer (./Install_omp) does this dir setup and
    # prebuilds the QCDLoop/TensorReduction static libs before the
    # top-level make can run -- the top makefile has no rule to create
    # its own obj_omp/ (or the QCDLoop/TensorReduction ones), it just
    # assumes Install_omp already ran. Replicated directly here instead
    # of calling Install_omp itself, since that script also tries to
    # typeset a LaTeX manual (no latex in this build env, and irrelevant
    # for a binary package).
    mkdir -p obj_omp
    mkdir -p QCDLoop/ff/obj_omp QCDLoop/ql/obj_omp
    mkdir -p TensorReduction/ov/obj_omp TensorReduction/pv/obj_omp \
             TensorReduction/recur/smallF/obj_omp TensorReduction/recur/smallG/obj_omp \
             TensorReduction/recur/smallP/obj_omp TensorReduction/recur/smallY/obj_omp

    # QCDLoop/makefile_omp's default target (`all: test`) links a
    # throwaway test binary with a hardcoded `-lff` that doesn't match
    # the `libff_omp.a` its own ffdir target just built (upstream bug in
    # this vendored copy) -- build only the qldir/ffdir prerequisites we
    # actually need (the .a files) and skip that broken link entirely.
    (cd QCDLoop && make -f makefile_omp qldir ffdir FC="${FC}")
    (cd TensorReduction && make -f makefile_omp libs FC="${FC}")

    NPROC=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
    make -j"$NPROC" \
      PDFROUTINES=LHAPDF \
      LHAPDFLIB="${PREFIX}/lib" \
      NTUPLES=NO \
      USEOMP=YES \
      FC="${FC}" F90="${FC}"

    mkdir -p "${PREFIX}/bin"
    cp Bin/mcfm_omp "${PREFIX}/bin/mcfm"
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
