# ANARI native bundle

Builds libanari and the ANARI devices in containers. The output is a single folder of native libraries, so applications do not have to compile or install ANARI themselves.

```
./build-bundle.sh                        # build the parts not built yet, then assemble the bundle
./build-bundle.sh sdk halogen            # rebuild these parts (and the parts not built yet)
./build-bundle.sh --only sdk halogen     # build only these parts, the others come from previous builds
./build-bundle.sh all                    # rebuild every part
./build-bundle.sh cycles -- --build-arg CYCLES_OPTIX=OFF --build-arg JOBS=8
```

The output goes to `dist/`:
- `dist/anari-linux-x86_64/lib/` holds libanari, the devices and all the libraries they need.
- `dist/anari-linux-x86_64/MANIFEST.txt` lists the devices and, per part, the commit of each component.
- `dist/anari-linux-x86_64/lib/licenses/` holds the licenses of the components (one folder per component), next to the libraries.
- `dist/anari-linux-x86_64.tar.gz` is the same folder, archived.
- `dist/parts/` holds the parts copied from the images, before merging.

libanari is `lib/libanari.so`. The devices are next to it (`lib/libanari_library_<name>.so`), where `anariLoadLibrary("<name>")` finds them.

## Parts and devices

The bundle is built in parts, one container image per part, so a part can be rebuilt without rebuilding the others.

| Part | Dockerfile | Devices | Needs at runtime |
|---|---|---|---|
| `sdk` | `Dockerfile.sdk` | `helide`, `debug`, `sink` | – |
| | | `halcyon` (Embree and ISPC) | – |
| | | `helide_gpu` (SDL3 SDL_gpu) | Vulkan driver and a display (X11 or Wayland). Experimental in the SDK. |
| `ospray` | `Dockerfile.ospray` | `ospray` (anari-ospray and the OSPRay binary release) | – |
| `visrtx` | `Dockerfile.visrtx` | `visrtx` | NVIDIA driver (CUDA 12.6 or newer), Turing or newer GPU |
| | | `visgl` | OpenGL with EGL |
| `cycles` | `Dockerfile.cycles` | `cycles` (anari-cycles and Blender's precompiled libraries) | NVIDIA driver for OptiX, CPU otherwise |
| `halogen` | `Dockerfile.halogen` | `halogen` ([Halogen](https://github.com/MetaversalCorp/Halogen), Google's Filament engine) | glibc 2.39 or newer: Ubuntu 24.04, Fedora 40, Debian 13 and newer |
| `barney` | `Dockerfile.barney` | `barney` ([Barney](https://github.com/NVIDIA/barney), NVIDIA's multi-GPU path tracer, OptiX backend, without MPI) | NVIDIA driver (CUDA 12.6 or newer), GPU of the CUDA architectures or newer (Pascal by default) |
| `photon` | `Dockerfile.photon` | `photon` ([Photon](https://github.com/mvictoras/photon), Kokkos path tracer with the Kokkos CUDA backend) | NVIDIA driver (CUDA 12.6 or newer), GPU of the Kokkos architecture or newer (Pascal by default). The repository has no license. |
| `webgpu` | `Dockerfile.webgpu` | `webgpu` ([anari-webgpu](https://github.com/sankhesh/anari-webgpu) with Google's [Dawn](https://dawn.googlesource.com/dawn) and [Slang](https://github.com/shader-slang/slang)) | Vulkan driver. Without it, the device falls back to a software rasterizer. Experimental: triangles, `matte` material and directional lights only. |
| `viskores` | `Dockerfile.viskores` | `viskores` ([Viskores](https://github.com/Viskores/viskores), the successor of VTK-m: ray tracing with its worklets, OpenMP backend) | – (CUDA backend optional, see `VISKORES_CUDA_ARCHS`) |

These devices are not built:
- `hydra` needs OpenUSD.
- `remote` needs a render server.

## How it works

- **Images:**
  - `anari-bundle-toolchain` (`Dockerfile.toolchain`): Rocky Linux 8 with CUDA 12.6 and the build tools. Rocky 8 has glibc 2.28, like Blender's builds, so these parts run on Linux distributions released since about 2018.
  - `anari-bundle-sdk`, `-ospray`, `-visrtx`, `-cycles`, `-webgpu`, `-photon`, `-barney` and `-viskores` are built from the toolchain image.
  - `anari-bundle-viskores` builds the ANARI module group of Viskores (the device and the interop library) with only the modules they need, as shared libraries. Viskores is built without logging: its logging library (loguru) installs signal handlers when the device loads, which replace those of the host process.
  - `anari-bundle-photon` builds Photon with its own libanari, not shipped, from the ANARI SDK of the other parts instead of the release Photon pins, so the device matches the bundle's libanari. Photon's dependencies (that ANARI SDK, Kokkos and the OIDN binary release, at the versions Photon pins) are fetched before the build and given to CMake's `FetchContent`. The Embree and OptiX ray tracing back-ends of Photon are not built: it uses its Kokkos one.
  - `anari-bundle-webgpu` adds GCC 14 (`gcc-toolset-14`) to the toolchain. It links Dawn's nightly binary release, a static library built with GCC 14 for glibc 2.28. anari-webgpu uses Dawn specific structures, so it is not built with wgpu-native. Its shaders are compiled at runtime by Slang: the glibc 2.28 build of the Slang version used by SlangKit is downloaded and given to CMake's `FetchContent`, with SlangKit at the commit anari-webgpu pins.
  - `anari-bundle-halogen` is built on Ubuntu 24.04 with Clang and libc++, because Filament's prebuilt libraries and its material compiler are built that way. It ships libc++.
- **libanari:** the bundle ships the libanari of the `sdk` part. The other images build their own copy of libanari (without devices) to link with, and do not ship it. A change to the `sdk` part therefore does not rebuild the other parts. Pin `ANARI_SDK_REF` so all parts use the same ANARI SDK version.
- **Steps:** in each image, each component has a fetch step (clone and downloads), then a build step (configure, compile, install), then the part is collected in `/bundle/<part>`.
- **Collection:** `scripts/collect-part.sh` copies the device libraries and their whole dependency closure, found with `ldd`.
  - It skips the libraries every system or GPU driver provides: glibc, libstdc++, libgcc, OpenGL/EGL, Vulkan, X11/Wayland, the CUDA driver and OptiX.
  - Every library gets the search path `$ORIGIN`, so they find each other without `LD_LIBRARY_PATH`, including the devices libanari opens with `dlopen`.
  - Each image checks that its devices find their libraries in the part, and prints the result.
- **Assembly:** `build-bundle.sh` copies each part from its image, then `assemble-bundle.sh` merges them. When two parts ship the same library (TBB, OIDN, Embree), the newest version is kept. It then checks the devices on the build machine.
- **Previous builds:** a part whose image does not exist is taken from its copy in `dist/parts/` if there is one. Other folders in `dist/parts/`, such as `dist/parts/previous` (the bundle built with the former single Dockerfile), are merged last: they only provide what the other parts do not have.

## GitHub workflow

The `Release Linux` workflow (`.github/workflows/release-linux.yml`) builds the same images on GitHub runners, one job per part, then merges the parts with `assemble-bundle.sh` and publishes `anari-linux-x86_64-<version>.tar.gz` in a release tagged `linux/<version>`. The options below are given in its `build-args` field, space separated: `ANARI_SDK_REF=v0.15.0 CYCLES_OPTIX=ON`. The workflow has its own defaults, used unless given in `build-args`: `JOBS=3`, because the runners have 4 cores and 16 GB of memory, and `CYCLES_OPTIX=OFF`, because the Cycles GPU kernels take hours to compile on 4 cores (a job is stopped after 6 hours). The Cycles device of the release is therefore CPU only by default.

## Restarting after a failure

Run `./build-bundle.sh` again: it restarts close to where it stopped. When a part fails, the other parts are still built and assembled, and the failed parts are listed at the end.

- **Steps that succeeded are reused.** Every step is an image layer. The container engine reruns only the failed step and the steps after it.
- **A failed compilation resumes.** The build folders (`/src/<component>/build`) are cache mounts, which the container engine keeps across builds even when a step fails. Ninja then recompiles only what was not finished.
- **Changes rerun only what follows them.** Each build argument and each script is declared just before the steps that use it. For example, changing `CYCLES_CUDA_ARCHS` or editing `build-cycles.sh` reruns only the Cycles build of the `cycles` part. Editing `common.sh` reruns every Rocky Linux part.
- **Sources are fetched once.** With an empty `*_REF`, the default branch is cloned on the first build and kept in its layer. To fetch the latest sources again, pass `-- --no-cache`.

To clear the cached build folders:
- with Docker: `docker builder prune --filter type=exec.cachemount`;
- with Podman (also when `docker` is Podman's emulation): `podman image prune --build-cache`, or remove `/var/tmp/buildah-cache-$(id -u)`.

## Options

Pass them after `--` as `--build-arg NAME=value`. Arguments not used by a part are ignored.

| Argument | Default | Meaning |
|---|---|---|
| `ANARI_SDK_REF`, `VISRTX_REF`, `ANARI_OSPRAY_REF`, `ANARI_CYCLES_REF`, `HALOGEN_REF`, `ANARI_WEBGPU_REF` | default branch | Git branch or tag of each component |
| `DAWN_RELEASE` | latest | Dawn binary release tag, for example `v20261112.214115` |
| `BARNEY_REF` | default branch | Barney branch or tag |
| `BARNEY_CUDA_ARCHS` | 61 | CUDA architectures of Barney, for example `"61;86"`. The kernels also run on newer GPUs through their PTX. |
| `BARNEY_BACKEND_CPU` | OFF | `ON` adds Barney's Embree CPU backend, used when no NVIDIA GPU is found |
| `VISKORES_REF` | default branch | Viskores branch or tag |
| `VISKORES_CUDA_ARCHS` | empty | CUDA architectures to add the Viskores CUDA backend, for example `"61;86"`. Empty builds the OpenMP backend only. Viskores selects the backend at runtime. |
| `PHOTON_REF` | default branch | Photon branch or tag |
| `PHOTON_KOKKOS_ARCH` | PASCAL61 | Kokkos GPU architecture of Photon: `PASCAL61`, `VOLTA70`, `TURING75`, `AMPERE80`, `AMPERE86`, `ADA89`, `HOPPER90`... The kernels also run on newer GPUs through their PTX. |
| `OSPRAY_VERSION` | 3.2.0 | OSPRay binary release |
| `ISPC_VERSION` | 1.28.2 | ISPC release, used by halcyon (the version of the SDK continuous integration) |
| `SDL3_REF`, `GLSLANG_REF` | release-3.4.20, 16.6.0 | SDL3 and glslang tags, used by helide_gpu |
| `CYCLES_OPTIX` | ON | Build the Cycles CUDA/OptiX kernels. `OFF` gives a CPU-only build, which is much faster to compile. |
| `CYCLES_CUDA_ARCHS` | compute_75 | Cycles kernels: `compute_XX` is PTX, compiled by the driver on first use; `sm_XX` is native code. Example: `"compute_75;sm_86;sm_89"`. |
| `VISRTX_MIN_ARCH` | VisRTX default | Oldest GPU compute capability supported by VisRTX |
| `JOBS` | all cores | Parallel compile jobs. Lower it if the build runs out of memory: the CUDA kernels need about 4 GB per job. |
| `CUDA_IMAGE` | nvidia/cuda:12.6.3-devel-rockylinux8 | Base of the toolchain image |
| `UBUNTU_IMAGE` | ubuntu:24.04 | Base of the halogen image |

## Running inside a Flatpak sandbox

From a Flatpak application (for example VS Code installed with Flatpak), the system's OpenGL and Vulkan libraries are visible in `/run/host/usr/lib64`, but not the files telling them which driver to load. VisGL and helide_gpu then fail to start. Point them to the system's files:

```
export __EGL_VENDOR_LIBRARY_DIRS=/run/host/usr/share/glvnd/egl_vendor.d
export LD_LIBRARY_PATH=/run/host/usr/lib64
```

The Vulkan driver file of the system gives the driver with an absolute path (`/usr/lib64/libGLX_nvidia.so.0`), which in the sandbox is the Flatpak's folder. Use a copy pointing to `/run/host` :

```
sed 's#"/usr/lib64/#"/run/host/usr/lib64/#' /run/host/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json > ~/nvidia_icd_sandbox.json
export VK_DRIVER_FILES=~/nvidia_icd_sandbox.json
```

## Requirements

- Docker or Podman. The build does not need a GPU.
- About 35 GB of disk space. The Blender precompiled libraries alone take several GB.
- A network connection. The build fetches the sources from GitHub, the Blender libraries from projects.blender.org and Filament from GitHub.
- Build time: about 1 to 2 hours on 16 cores for all parts, most of it for the Cycles GPU kernels. The other parts take a few minutes to half an hour each.
- The bundle is about 1 to 2 GB uncompressed. The largest parts are OSPRay, OIDN with its GPU models, and the Cycles kernels.
