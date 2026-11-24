#!/bin/bash
# libanari alone, without devices : the device images link with it. It is not shipped, the bundle
# uses the libanari of the sdk part. Kept apart from build-anari-sdk.sh so that a change to the
# sdk part does not rebuild the device images.
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
        -DBUILD_HELIDE_DEVICE=OFF \
        -DBUILD_HELIDE_GPU_DEVICE=OFF \
        -DBUILD_HALCYON_DEVICE=OFF \
        -DBUILD_DEBUG_DEVICE=OFF \
        -DBUILD_SINK_DEVICE=OFF
    ;;
*) usage ;;
esac
