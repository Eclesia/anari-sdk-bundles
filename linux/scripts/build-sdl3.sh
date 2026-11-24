#!/bin/bash
# SDL3 (SDL_gpu, Vulkan backend), needed by the helide_gpu device. Rocky Linux 8 does not provide it.
# SDL3 loads X11, Wayland and Vulkan at runtime from the system.
source /scripts/common.sh

case "${1:-}" in
fetch)
    clone https://github.com/libsdl-org/SDL.git "${SRC}/SDL" "${2:-}"
    ;;
build)
    cmake_build "${SRC}/SDL" "${2:-}" \
        -DSDL_SHARED=ON \
        -DSDL_STATIC=OFF \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_GPU=ON \
        -DSDL_VULKAN=ON \
        -DSDL_X11=ON \
        -DSDL_X11_XTEST=OFF \
        -DSDL_WAYLAND=ON
    ;;
*) usage ;;
esac
