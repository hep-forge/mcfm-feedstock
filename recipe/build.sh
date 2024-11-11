#! /usr/bin/bash

if [ -d MCFM-* ]; then
    mv MCFM-*/* .
    rm -rf MCFM-*
fi

export LD=$FC
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
