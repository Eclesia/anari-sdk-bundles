#!/bin/bash
# Halogen device (https://github.com/MetaversalCorp/Halogen), an ANARI implementation of Google's
# Filament engine. Built with its own ANARI SDK submodule and the Filament release it pins.
# Halogen has no install rule, the device library is copied from the build folder.
source /scripts/common.sh
src="${SRC}/Halogen"

case "${1:-}" in
fetch)
    clone https://github.com/MetaversalCorp/Halogen.git "${src}" "${2:-}"
    # Filament release pinned by Halogen, downloaded here so it is kept in this layer
    version=$(sed -nE 's/^set\(FILAMENT_VERSION "([^"]+)".*/\1/p' "${src}/CMakeLists.txt")
    if [ -n "${version}" ]; then
        mkdir -p "${src}/external/filament"
        wget -q -O /tmp/filament.tgz \
            "https://github.com/google/filament/releases/download/v${version}/filament-v${version}-linux.tgz"
        tar -xzf /tmp/filament.tgz -C "${src}/external/filament" --strip-components=1
        rm /tmp/filament.tgz
        #layout checked by Halogen's DownloadFilament.cmake, otherwise CMake downloads it again
        test -f "${src}/external/filament/README.md" || echo "Unexpected Filament archive layout, CMake will download it"
        echo "filament ${version} binary release (Ubuntu 24.04 build, needs glibc 2.39 or newer)" >> "${PREFIX}/MANIFEST.txt"
    fi
    # Halogen builds with -Werror and is tested with an older Clang : warnings added by newer
    # Clang versions would stop the build
    sed -i '/:-Werror>/d' "${src}/src/CMakeLists.txt"
    # Halogen uses LightManager::Builder::global(), which no released Filament version has
    # (Halogen 2026-09-04 "Punctual global-light bypass"). Removed : it only makes point and spot
    # lights far outside the view reach every fragment.
    sed -i '/\.global(global)/d' "${src}/src/Light.cpp"
    if grep -q 'Builder::global\|\.global(' "${src}/src/Light.cpp"; then
        echo "Light.cpp still uses LightManager::Builder::global, update build-halogen.sh" >&2
        exit 1
    fi
    ;;
build)
    # some objects linked into the device (Filament's prebuilt libraries) are not marked as not
    # needing an executable stack : glibc 2.41 and newer refuse to load such a library
    cmake -S "${src}" -B "${src}/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTS=OFF \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS:-} -Wl,-z,noexecstack" \
        -DFILAMENT_SDK_DIR="${src}/external/filament"
    cmake --build "${src}/build" -j "$(jobs "${2:-}")" --target anari_library_halogen
    device=$(find "${src}/build" -name 'libanari_library_halogen.so' | head -1)
    test -n "${device}" || { echo "libanari_library_halogen.so not found in ${src}/build"; exit 1; }
    if readelf -lW "${device}" | grep GNU_STACK | grep -q RWE; then
        echo "${device} still requires an executable stack" >&2
        exit 1
    fi
    mkdir -p "${PREFIX}/lib"
    cp "${device}" "${PREFIX}/lib/"
    ;;
bundle)
    bash /scripts/collect-part.sh \
        -l halogen="${src}" \
        -l filament="${src}/external/filament" \
        -l corrade="${src}/external/corrade" \
        "${PREFIX}/lib/libanari_library_halogen.so"
    ;;
*) usage ;;
esac
