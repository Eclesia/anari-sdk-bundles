#!/bin/bash
# VisRTX (CUDA/OptiX) and VisGL (OpenGL) devices. The OptiX headers are downloaded by the build,
# the OptiX and CUDA runtimes come from the NVIDIA driver of the user. The OptiX shaders are not
# precompiled at install : it needs a GPU, and the result is the driver cache of the build machine.
source /scripts/common.sh

case "${1:-}" in
fetch)
    clone https://github.com/NVIDIA/VisRTX.git "${SRC}/VisRTX" "${2:-}"
    ;;
build)
    minArch="${3:-}"
    args=()
    if [ -n "${minArch}" ]; then args+=(-DVISRTX_MIN_ARCH="${minArch}"); fi
    cmake_build "${SRC}/VisRTX" "${2:-}" \
        -DVISRTX_BUILD_RTX_DEVICE=ON \
        -DVISRTX_BUILD_GL_DEVICE=ON \
        -DVISRTX_BUILD_TSD=OFF \
        -DVISRTX_BUILD_TESTS=OFF \
        -DCMAKE_CUDA_HOST_COMPILER="${CUDAHOSTCXX}" \
        -DVISRTX_PRECOMPILE_SHADERS=OFF \
        "${args[@]}"
    ;;
bundle)
    bash /scripts/collect-part.sh \
        -l visrtx="${SRC}/VisRTX" \
        "${PREFIX}/lib/libanari_library_visrtx.so" \
        "${PREFIX}/lib/libanari_library_visgl.so"
    ;;
*) usage ;;
esac
