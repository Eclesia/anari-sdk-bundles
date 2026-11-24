# ANARI native bundle for macOS arm64

Builds libanari and the ANARI devices for Apple silicon with Apple Clang and Ninja. The output is one folder of libraries.

```
brew install cmake ninja spirv-cross libomp
python3 build.py part sdk                        # build one part in dist/parts/sdk
python3 build.py assemble anari-macos-arm64 sdk ospray halogen viskores
```

Needs the Xcode command line tools, git and Python 3.9 or newer. The sources and build folders go to `work/`.

The output goes to `dist/`:
- `dist/parts/<part>/` holds each part: `lib/`, `licenses/` and `MANIFEST.txt`.
- `dist/<name>/lib/` holds libanari, the devices and every library they need, and in `lib/licenses/` the licenses of the components (one folder per component).
- `dist/<name>.tar.gz` is the same folder, archived.

libanari is `lib/libanari.dylib`. The devices are next to it (`lib/libanari_library_<name>.dylib`), where `anariLoadLibrary("<name>")` finds them.

The libraries have an ad hoc signature only. When the archive was downloaded with a web browser, remove the quarantine attribute first, otherwise macOS refuses to load them:

```
xattr -dr com.apple.quarantine /path/to/anari-macos-arm64
```

## Parts and devices

| Part | Devices | Needs at runtime |
|---|---|---|
| `sdk` | `helide`, `debug`, `sink`, `halcyon` (Embree and ISPC), `helide_gpu` (SDL3 SDL_gpu with Metal, shaders translated by spirv-cross) | – |
| `ospray` | `ospray` (anari-ospray and the OSPRay binary release) | – |
| `halogen` | `halogen` (Google's Filament engine) | – |
| `viskores` | `viskores` (Viskores worklets, OpenMP with Homebrew's libomp, shipped) | libomp of Homebrew may need the macOS version of the build machine |

These Linux parts are not built on macOS: `visrtx`, `photon` and `barney` need CUDA, which macOS does not have. `cycles` and `webgpu` have no upstream macOS build to follow yet.

## How it works

- **Steps:** each part clones its components, builds them with CMake and installs them in `work/<part>/install`. Each part except `sdk` builds its own libanari to link with, not shipped: the bundle ships the one of `sdk`.
- **Deployment target:** 14.0 by default (`MACOS_DEPLOYMENT_TARGET`), arm64 only.
- **Embree** is built from source as a static library, like on Linux (`CMAKE_DISABLE_FIND_PACKAGE_embree`).
- **Halogen** gets the same source changes as on Linux (no `-Werror`, no `LightManager::Builder::global()`), and downloads the Filament release it pins.
- **Viskores** is built without logging, like on Linux: its logging library installs signal handlers when the device loads, which replace those of the host process.
- **Collection:** the device libraries and their dependency closure, read with `otool -L`, are copied to `lib/`. Every library then refers to the others as `@rpath/<name>`, with the single search path `@loader_path`, and is signed again with an ad hoc signature (Apple silicon refuses to load a modified library otherwise). System libraries and frameworks (`/usr/lib`, `/System`) and Vulkan/MoltenVK are skipped.
- **Check:** each part, and the assembled bundle, prints for each device the libraries not found and whether macOS loads it the way libanari does.
- **Assembly:** the parts are merged in the given order, symbolic links kept. When two parts ship a library with the same name and different content, the one of the first part is kept and the conflict is printed.

## Options

Environment variables, with the names of the Linux build arguments. On GitHub, give them in the `build-args` field of the `Release macOS` workflow (`.github/workflows/release-macos.yml`), which sets `JOBS=3` unless given.

| Variable | Default | Meaning |
|---|---|---|
| `ANARI_SDK_REF`, `ANARI_OSPRAY_REF`, `HALOGEN_REF`, `VISKORES_REF` | default branch | Git branch or tag of each component |
| `OSPRAY_VERSION` | 3.2.0 | OSPRay binary release |
| `ISPC_VERSION` | 1.28.2 | ISPC release, for halcyon |
| `SDL3_REF`, `GLSLANG_REF` | release-3.4.20, 16.6.0 | SDL3 and glslang tags, for helide_gpu |
| `MACOS_DEPLOYMENT_TARGET` | 14.0 | Oldest macOS version |
| `JOBS` | all cores (3 on GitHub) | Parallel compile jobs |
