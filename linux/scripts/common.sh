#!/bin/bash
# Shared settings of the build scripts.
#
# Each component script has a "fetch" step (sources, downloads) and a "build" step (configure,
# compile, install), run as separate image layers. The build folders are cache mounts kept by
# the container engine across builds, so a failed build resumes where the compilation stopped.
set -euo pipefail

# All ANARI libraries are installed in this prefix, libraries in lib/
export PREFIX=/opt/anari
export SRC=/src
export OSPRAY_ROOT=/opt/ospray
export ISPC_ROOT=/opt/ispc
export GLSLANG_ROOT=/opt/glslang
mkdir -p "${PREFIX}" "${SRC}"

# Clone a repository at a branch or tag, the default branch when the ref is empty.
# The commit is recorded in the bundle manifest.
clone() {
    local url="$1" dir="$2" ref="${3:-}"
    if [ -n "${ref}" ]; then
        git clone --depth 1 --branch "${ref}" --recurse-submodules --shallow-submodules "${url}" "${dir}"
    else
        git clone --depth 1 --recurse-submodules --shallow-submodules "${url}" "${dir}"
    fi
    echo "$(basename "${dir}") $(git -C "${dir}" rev-parse HEAD) ${url}" >> "${PREFIX}/MANIFEST.txt"
}

jobs() {
    if [ -n "${1:-}" ]; then echo "$1"; else nproc; fi
}

# Configure (fast when the cached build folder is already configured), compile and install
# a CMake project. Usage : cmake_build <source dir> <jobs> [cmake options...]
cmake_build() {
    local src="$1" jobs="$2"
    shift 2
    cmake -S "${src}" -B "${src}/build" "${cmake_common[@]}" "$@"
    cmake --build "${src}/build" -j "$(jobs "${jobs}")"
    cmake --install "${src}/build"
}

usage() {
    echo "usage: $(basename "$0") fetch|build [arguments]" >&2
    exit 2
}

cmake_common=(
    -G Ninja
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${PREFIX}"
    -DCMAKE_INSTALL_LIBDIR=lib
    -DCMAKE_PREFIX_PATH="${PREFIX}"
)
