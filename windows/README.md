# ANARI native bundle for Windows x86_64

Builds libanari and the ANARI devices with Visual Studio 2022 (MSVC, Ninja). The output is one folder of DLLs.

```
python build.py part sdk                         # build one part in dist/parts/sdk
python build.py assemble anari-windows-x86_64 sdk ospray visrtx halogen
```

Run it from a "x64 Native Tools Command Prompt for VS 2022" (or PowerShell with that environment), with CMake, Ninja, git and Python 3.9 or newer. The visrtx part also needs the CUDA toolkit. The sources and build folders go to `work\`, or `%RUNNER_TEMP%\w` on GitHub; keep that path short, some components have deep source trees.

The output goes to `dist\`:
- `dist\parts\<part>\` holds each part: `bin\`, `licenses\` and `MANIFEST.txt`.
- `dist\<name>\bin\` holds anari.dll, the devices and every DLL they need, including the Visual C++ runtime, and in `bin\licenses\` the licenses of the components (one folder per component).
- `dist\<name>.zip` is the same folder, archived.

libanari is `bin\anari.dll`. The devices are next to it (`bin\anari_library_<name>.dll`), where `anariLoadLibrary("<name>")` finds them. `PATH` does not need to be changed: libanari loads a device by its full path with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR`, so Windows finds the DLLs next to it.

## Parts and devices

| Part | Devices | Needs at runtime |
|---|---|---|
| `sdk` | `helide`, `debug`, `sink`, `halcyon` (Embree and ISPC), `helide_gpu` (SDL3 SDL_gpu) | helide_gpu: Vulkan or Direct3D 12 driver |
| `ospray` | `ospray` (anari-ospray and the OSPRay binary release) | – |
| `visrtx` | `visrtx`, `visgl` (OpenGL through WGL) | visrtx: NVIDIA driver (CUDA 12.4 or newer), Turing or newer GPU |
| `halogen` | `halogen` (Google's Filament engine) | – |

These Linux parts are not built on Windows yet: `cycles` and `webgpu` (no upstream Windows build to follow), `photon` and `barney` (CUDA builds on Windows not tested upstream), `viskores` (only the serial backend is tested upstream on Windows).

## How it works

- **Steps:** each part clones its components, builds them with CMake and installs them in `work\<part>\install`. Each part except `sdk` builds its own anari.dll to link with, not shipped: the bundle ships the one of `sdk`.
- **Embree** is built from source as a static library, like on Linux (`CMAKE_DISABLE_FIND_PACKAGE_embree`).
- **Halogen** gets the same source changes as on Linux (no `-Werror`, no `LightManager::Builder::global()`), and downloads the Filament release it pins.
- **CUDA:** on GitHub, the visrtx job installs CUDA 12.4.1 with the installer of VisRTX's own continuous integration.
- **Collection:** the device DLLs and their dependency closure, read with `dumpbin /dependents` (delay-loaded DLLs included), are copied to `bin\`. Windows DLLs and those of the GPU driver (nvcuda, nvml, nvoptix, vulkan-1, opengl32) are skipped. The Visual C++ runtime DLLs are copied from the Visual Studio redistributable folder.
- **Check:** each part, and the assembled bundle, prints for each device the DLLs not found and whether Windows loads it the way libanari does. visrtx does not load on a machine without NVIDIA driver, such as the GitHub runners.
- **Assembly:** the parts are merged in the given order. When two parts ship a DLL with the same name and different content, the one of the first part is kept and the conflict is printed.

## Options

Environment variables, with the names of the Linux build arguments. On GitHub, give them in the `build-args` field of the `Release Windows` workflow (`.github/workflows/release-windows.yml`), which sets `JOBS=3` unless given.

| Variable | Default | Meaning |
|---|---|---|
| `ANARI_SDK_REF`, `ANARI_OSPRAY_REF`, `VISRTX_REF`, `HALOGEN_REF` | default branch | Git branch or tag of each component |
| `OSPRAY_VERSION` | 3.2.0 | OSPRay binary release |
| `ISPC_VERSION` | 1.28.2 | ISPC release, for halcyon |
| `SDL3_REF`, `GLSLANG_REF` | release-3.4.20, 16.6.0 | SDL3 and glslang tags, for helide_gpu |
| `VISRTX_MIN_ARCH` | VisRTX default | Oldest GPU compute capability supported by VisRTX |
| `JOBS` | all cores (3 on GitHub) | Parallel compile jobs |
