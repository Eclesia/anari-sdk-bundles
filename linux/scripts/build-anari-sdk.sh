#!/bin/bash
# ANARI SDK : libanari and the devices of the SDK (helide, helide_gpu, halcyon, debug, sink).
# The hydra device needs OpenUSD and the remote device a server, they are not built.
# halcyon fetches and builds Embree itself, helide_gpu needs SDL3 and glslang. helide_gpu fetches
# glm, built here as headers only : with BUILD_SHARED_LIBS it would be a libglm.so, never installed.
# halcyon looks for Imath before fetching it : when the cached build folder is configured again,
# it finds the Imath fetched by the first configure but without its Imath::Imath target, so the
# search is disabled and Imath is always the fetched one.
source /scripts/common.sh

case "${1:-}" in
fetch)
    clone https://github.com/KhronosGroup/ANARI-SDK.git "${SRC}/ANARI-SDK" "${2:-}"
    ;;
build)
    cmake_build "${SRC}/ANARI-SDK" "${2:-}" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_VIEWER=OFF \
        -DBUILD_CTS=OFF \
        -DBUILD_HELIDE_DEVICE=ON \
        -DBUILD_HELIDE_GPU_DEVICE=ON \
        -DGLSLANG_VALIDATOR="${GLSLANG_ROOT}/bin/glslangValidator" \
        -DGLM_BUILD_LIBRARY=OFF \
        -DBUILD_HALCYON_DEVICE=ON \
        -DCMAKE_ISPC_COMPILER="${ISPC_ROOT}/bin/ispc-nopthread" \
        -DCMAKE_DISABLE_FIND_PACKAGE_Imath=ON \
        -DBUILD_DEBUG_DEVICE=ON \
        -DBUILD_SINK_DEVICE=ON
    ;;
bundle)
    # libanari, the SDK devices and their libraries. helide_gpu opens SDL3 with dlopen at first use
    # (implib-gen stubs), so ldd does not list it : SDL3 is copied explicitly.
    bash /scripts/collect-part.sh \
        -l anari-sdk="${SRC}/ANARI-SDK" \
        -l sdl3="${SRC}/SDL" \
        "${PREFIX}/lib/libanari*.so*" \
        "${PREFIX}/lib/libSDL3.so*"
    ;;
*) usage ;;
esac
