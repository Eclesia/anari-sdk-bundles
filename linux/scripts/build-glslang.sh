#!/bin/bash
# glslang shader compiler, used to build the helide_gpu device. Not part of the bundle.
source /scripts/common.sh

case "${1:-}" in
fetch)
    clone https://github.com/KhronosGroup/glslang.git "${SRC}/glslang" "${2:-}"
    ;;
build)
    cmake_build "${SRC}/glslang" "${2:-}" \
        -DCMAKE_INSTALL_PREFIX="${GLSLANG_ROOT}" \
        -DENABLE_OPT=OFF \
        -DGLSLANG_TESTS=OFF \
        -DENABLE_GLSLANG_BINARIES=ON \
        -DBUILD_SHARED_LIBS=OFF
    ;;
*) usage ;;
esac
