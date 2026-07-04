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
