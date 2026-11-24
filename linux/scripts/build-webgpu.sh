#!/bin/bash
# WebGPU device (https://github.com/sankhesh/anari-webgpu), built with Google's Dawn.
#
# anari-webgpu uses Dawn specific structures (WGPUDawnTogglesDescriptor), so the Dawn backend is
# used, not wgpu-native. Dawn comes from its nightly binary release : a static library built with
# GCC 14 for glibc 2.28, linked into the device. The shaders are compiled at runtime with Slang
# (through SlangKit, fetched by anari-webgpu's CMake) : its glibc 2.28 binary release is downloaded
# here and given to FetchContent, which would otherwise download a build needing a newer glibc.
#
#   build-webgpu.sh fetch [anari-webgpu ref] [Dawn release tag]   empty for the latest
#   build-webgpu.sh build [jobs]
#   build-webgpu.sh bundle
source /scripts/common.sh
src="${SRC}/anari-webgpu"
DAWN_ROOT=/opt/dawn
SLANG_ROOT=/opt/slang
SLANGKIT_SRC="${SRC}/SlangKit"

# GitHub release JSON, latest when the tag is empty
release_json() {
    local repo="$1" tag="${2:-}"
    if [ -n "${tag}" ]; then
        wget -q -O - "https://api.github.com/repos/${repo}/releases/tags/${tag}"
    else
        wget -q -O - "https://api.github.com/repos/${repo}/releases/latest"
    fi
}

case "${1:-}" in
fetch)
    clone https://github.com/sankhesh/anari-webgpu.git "${src}" "${2:-}"

    # Dawn nightly release : the Release archive, ubuntu-latest is the name of the CI runner
    json=$(release_json google/dawn "${3:-}")
    tag=$(echo "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
    url=$(echo "${json}" | python3 -c '
import json, sys
for a in json.load(sys.stdin)["assets"]:
    if a["name"].endswith("-ubuntu-latest-Release.tar.gz"):
        print(a["browser_download_url"])
        break')
    test -n "${url}" || { echo "No Linux release archive in Dawn release ${tag}" >&2; exit 1; }
    mkdir -p "${DAWN_ROOT}"
    wget -q -O /tmp/dawn.tar.gz "${url}"
    tar -xzf /tmp/dawn.tar.gz -C "${DAWN_ROOT}" --strip-components=1
    rm /tmp/dawn.tar.gz
    test -f "${DAWN_ROOT}/lib64/cmake/Dawn/DawnConfig.cmake" || { echo "Unexpected Dawn archive layout" >&2; exit 1; }
    commit=$(basename "${url}" .tar.gz | sed -E 's/^Dawn-([0-9a-f]+)-.*/\1/')
    # the archive has no license file : the one of the same commit
    wget -q -O "${DAWN_ROOT}/LICENSE" "https://raw.githubusercontent.com/google/dawn/${commit}/LICENSE"
    echo "Dawn ${commit} https://github.com/google/dawn (binary release ${tag})" >> "${PREFIX}/MANIFEST.txt"

    # SlangKit, at the commit pinned by anari-webgpu
    slangkit=$(sed -n '/FetchContent_Declare(SlangKit/,/)/p' "${src}/CMakeLists.txt" | sed -nE 's/.*GIT_TAG +([0-9a-f]+).*/\1/p')
    test -n "${slangkit}" || { echo "SlangKit commit not found in ${src}/CMakeLists.txt" >&2; exit 1; }
    git clone https://github.com/sankhesh/SlangKit.git "${SLANGKIT_SRC}"
    git -C "${SLANGKIT_SRC}" checkout --quiet "${slangkit}"
    echo "SlangKit ${slangkit} https://github.com/sankhesh/SlangKit.git" >> "${PREFIX}/MANIFEST.txt"

    # Slang, at the version used by SlangKit, built for glibc 2.28
    version=$(sed -nE 's/.*set\(_SLANG_VER "([^"]+)"\).*/\1/p' "${SLANGKIT_SRC}/CMakeLists.txt" | head -1)
    test -n "${version}" || { echo "Slang version not found in SlangKit" >&2; exit 1; }
    mkdir -p "${SLANG_ROOT}"
    wget -q -O /tmp/slang.tar.gz \
        "https://github.com/shader-slang/slang/releases/download/v${version}/slang-${version}-linux-x86_64-glibc-2.28.tar.gz"
    tar -xzf /tmp/slang.tar.gz -C "${SLANG_ROOT}"
    rm /tmp/slang.tar.gz
    test -f "${SLANG_ROOT}/lib/libslang.so" && test -f "${SLANG_ROOT}/include/slang.h" \
        || { echo "Unexpected Slang archive layout" >&2; exit 1; }
    echo "slang ${version} binary release (glibc 2.28 build)" >> "${PREFIX}/MANIFEST.txt"
    ;;
build)
    # FetchContent uses the sources fetched above instead of downloading them
    cmake -S "${src}" -B "${src}/build" "${cmake_common[@]}" \
        -DWEBGPU_BACKEND=dawn \
        -DDawn_DIR="${DAWN_ROOT}/lib64/cmake/Dawn" \
        -DDAWN_DIR="${DAWN_ROOT}" \
        -DFETCHCONTENT_SOURCE_DIR_SLANGKIT="${SLANGKIT_SRC}" \
        -DFETCHCONTENT_SOURCE_DIR_SLANG_DIST="${SLANG_ROOT}" \
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
        -DBUILD_TESTS=OFF \
        -DBUILD_WEBGPU_EXAMPLE=OFF \
        -DSLANGKIT_BUILD_TESTING=OFF
    cmake --build "${src}/build" -j "$(jobs "${2:-}")" --target anari_library_webgpu
    device=$(find "${src}/build" -name 'libanari_library_webgpu.so*' -type f | head -1)
    test -n "${device}" || { echo "libanari_library_webgpu.so not found in ${src}/build" >&2; exit 1; }
    mkdir -p "${PREFIX}/lib"
    cp "${device}" "${PREFIX}/lib/libanari_library_webgpu.so"
    # SlangKit is a shared library of the build folder, which is a cache mount not kept in the image
    slangkit=$(find "${src}/build" -name 'libSlangKit.so*' | head -1)
    test -n "${slangkit}" || { echo "libSlangKit.so not found in ${src}/build" >&2; exit 1; }
    cp -a "$(dirname "${slangkit}")"/libSlangKit.so* "${PREFIX}/lib/"
    ;;
bundle)
    # libslang and the libraries it opens at runtime (code generation back-ends) are seeds :
    # ldd does not list what Slang opens with dlopen
    bash /scripts/collect-part.sh \
        -p "${SLANG_ROOT}/lib" \
        -l anari-webgpu="${src}" \
        -l slangkit="${SLANGKIT_SRC}" \
        -l slang="${SLANG_ROOT}" \
        -l dawn="${DAWN_ROOT}" \
        "${PREFIX}/lib/libanari_library_webgpu.so" \
        "${SLANG_ROOT}/lib/libslang*.so*"
    ;;
*) usage ;;
esac
