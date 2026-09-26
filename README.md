<div align="center">

# 🧱 FlameLauncher SDL3 &amp; Natives

**Native build scripts, patches and prebuilt releases for running a Minecraft: Java Edition
launcher on iOS and Android — SDL3, LWJGL 3.4.3 and the renderer stack.**

[![target](https://img.shields.io/badge/target-iOS%20arm64%20%C2%B7%20Android%20arm64--v8a-000000?logo=apple&logoColor=white)](#)
[![releases](https://img.shields.io/badge/prebuilt-releases-green)](../../releases)
[![patches](https://img.shields.io/badge/patches-974%20lines-orange)](patches)
[![AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

</div>

---
---

Running Minecraft Java on a phone means building the renderer, LWJGL, SDL3 and the P2P
networking for `aarch64-apple-ios` (and arm64-v8a) — and **no upstream ships an iOS build.**
Where an Android build exists, it does not even compile as-is.

**SDL3 and the LWJGL 3.4.3 natives are published as releases** (see below), so a launcher can
take the binaries instead of the build.

This repository is the set of patches that close that gap. It was written for
[FlameLauncher for iOS](https://github.com/FlameLaunchers/FlameLauncher-iOS) but
**references no app code at all** — PojavLauncher iOS, Amethyst and others can use it
unchanged.

```
Scripts/       the build scripts; CI runs exactly these
patches/       the complete diff each script produces (974 lines)
JavaPatches/   Java stubs that build-javaapp.sh puts into launcher.jar
licenses/      the full licence text of all nine upstreams that get built
```

**Patched upstream trees are not vendored.** With submodules that would be hundreds of
megabytes, of which 974 lines actually changed. Instead each script clones, patches and
builds at build time, writing the resulting diff into `patches/`.

Every patch sits behind a hard `assert`, so when upstream touches an anchor **the build
stops right there** rather than silently missing and producing a wrong binary.

---

## 1. What the patches are

| Script | Patches | Asserts | Diff | Output |
|---|---|---|---|---|
| `build-mobileglues.sh` | 19 | 29 | 766 lines | `libmobileglues.dylib` |
| `build-terracotta.sh` | 7 | 7 | 137 lines | `libterracotta.a` |
| `build-javaapp.sh` | 3 | 3 | 71 lines | `lwjgl.jar` · `launcher.jar` |
| `build-sdl3.sh` | 50 | 52 | — | `libSDL3.dylib` · `libSDL3.so` |
| `build-lwjgl-natives.sh` | — | — | — | `liblwjgl*.dylib` (3.4.3) |
| `build-lwjgl-natives-android.sh` | — | — | — | `liblwjgl*.so` (3.4.3) |
| `build-spirv-cross.sh` | — | — | — | `libspirv-cross.dylib` |
| `build-shaderc.sh` | — | — | — | `libshaderc.dylib` |

## SDL3 and LWJGL 3.4.3

### SDL3 — `Scripts/build-sdl3.sh`

Built from `release-3.4.16`. The patches are applied to a fresh clone, so you can read them as
a list of problems rather than as a fork.

**iOS**

- **UIKit entry points are marshalled to the main thread.** SDL treats "the thread that called
  `SDL_Init`" as the main thread, but a launcher starts the JVM on a background thread — so the
  thread Minecraft calls "Render thread" is, to UIKit, a background thread. Window, display,
  text-input and Vulkan surface calls are wrapped so they run on the real main queue.
  GL calls are deliberately *not* wrapped: a GL context belongs to the thread that made it
  current, and swap happens every frame.
- **The GL backend runs on EGL instead of EAGL.** Mobile GL translators (MobileGlues, gl4es,
  Zink) expose EGL; SDL's uikit backend only knew EAGL. `SDL_GL_LoadLibrary` now hands the path
  Minecraft passes (the file LWJGL itself opened) straight to SDL's EGL loader, and pins it with
  `SDL_HINT_OPENGL_LIBRARY` at override priority, so SDL and LWJGL end up in the *same* library.
  26.3's GL backend compares `glGetError` addresses and refuses the backend otherwise.
- **A GL surface is created per window, when the window is first used.** 26.3 creates a hidden
  utility window, makes its context there, and only much later creates the real game window.
  One surface for the whole run means the game window stays empty.
- **`SDL_WINDOW_UTILITY` windows are created without a `UIWindow`** and get a pbuffer surface.
  The uikit backend allows one window per display, and 26.3's two hidden helper windows were
  taking that slot away from the game.
- **`UIKit_GL_RestoreCurrentContext` is skipped on EGL.** It casts `SDL_GLContext` to
  `EAGLContext`, and ARC then retains it — with an EGL handle that is a crash in `objc_retain`
  on the first frame after the event pump.
- **The render thread is parked while the app is in the background**, because iOS kills a
  process that touches the GPU there.

**Android**

- Desktop GL is folded to ES 3.2 without changing the version SDL reports.
- `SDL_WINDOW_UTILITY` windows go offscreen (pbuffer), same reasoning as iOS — keying on
  `HIDDEN` too would push the real window offscreen, because the game window is created hidden
  and shown later.
- A resize event is pushed at creation.

### LWJGL 3.4.3 — `Scripts/build-lwjgl-natives.sh`, `Scripts/build-lwjgl-natives-android.sh`

LWJGL's ant build has no iOS target, so the sources are compiled directly with clang using the
flags from LWJGL's own `config/macos/build.xml`. `libffi` is built from source and linked
statically into `liblwjgl` — 3.4.x rebuilt its callback layer on top of it
(`LibFFI.ffi_get_closure_size`), and a 3.3.3 native simply has no such symbol.

Java and natives must be the *same* version. A 3.4.3 jar on 3.4.1 natives dies in class init
with `UnsatisfiedLinkError: MemoryUtil.ngetPageSize()`.

The Android script is kept separate on purpose: the sources are shared but the toolchain,
platform macros (`LWJGL_LINUX` vs `LWJGL_MACOS`) and link steps are different enough that a
merged script would be harder to read than two.

### The renderer — `build-mobileglues.sh` (19)

MobileGlues translates desktop GL into GLES. Upstream's CMake has an iOS branch, but it
**has never been compiled** — the releases are APKs.

**① Things that simply don't build**

- `__attribute__((alias))` — absent on Mach-O
- `__NR_gettid` — a Linux syscall number; Darwin uses `pthread_threadid_np`
- `-Wl,-Bsymbolic-functions` — GNU ld only, rejected by Apple ld

**② Things that break because the iOS host is ES 3.0**

The Android host is ES 3.2; on iOS the host is ANGLE Metal, which is **ES 3.0**. ANGLE
exports the whole ES 3.2 symbol set but refuses the calls on an ES 3.0 context — **no
error, nothing happens.** Fallbacks are added for `glFramebufferTexture` (3.2) and
`glGetTexLevelParameteriv` (3.1).

**③ Why shaders rendered nothing**

With Iris on, entities and the held item were invisible.

> Metal requires the **signedness** of a vertex format to match the shader declaration.
> GL and GLES do not.

Feeding `GL_UNSIGNED_SHORT` to an attribute declared `ivec3` passes in GL and makes Metal
reject the pipeline outright. The fix walks the program's integer attributes just before
drawing and re-binds them with matching signedness.

> This took a long time to find for a reason. MobileGlues' `CHECK_GL_ERROR` sits behind
> `#if GLOBAL_DEBUG`, so in a default build **all 226 call sites compile to `{}`.** The
> observation "there are no GL errors" rested on nothing. A companion patch turns error
> logging on permanently.

**④ A lookup that skipped its own library**

The Apple branch of `glx/lookup.cpp` reads:

```c
return dlsym((void*)(~(uintptr_t)0), name);
```

`~0` is `(void*)-1`, and that value means different things per platform. **On Android
(LP64) it is `RTLD_DEFAULT`; on Apple it is `RTLD_NEXT`** — search the objects *after* me.
So MobileGlues never returned its own `gl*` and handed back ANGLE's instead.

LWJGL 3.3.3 never takes this path, so it stayed hidden. 3.4.1 added `eglGetProcAddress` to
its `GetProcAddress` candidates and walked straight into it: **every** GL function then
resolved to ANGLE, `glGetIntegerv` reported ES 3.0, LWJGL mapped no GL 3.3+ entry points,
and Minecraft 26.2 died on a null `glGenSamplers`. `RTLD_SELF` fixes it.

**⑤ Memory**

A high-resolution server resource pack makes Minecraft build an 8192² atlas — 268 MB as
RGBA8, and briefly twice that with the upload buffer, which exceeds the iOS budget (about
3 GB on an iPhone 15) and gets the process jetsammed. The patch shrinks by powers of two
**only when the remaining headroom cannot hold it**, scaling sub-upload coordinates and
pixels to match. UVs are normalised, so the image still lands correctly.

### Online LAN — `build-terracotta.sh` (7)

The **first iOS build** of [Terracotta](https://github.com/PCL-Community/Terracotta-lib)
(built on EasyTier).

Upstream [burningtnt/Terracotta](https://github.com/burningtnt/Terracotta) cannot work on
iOS at all: it embeds an EasyTier executable and spawns it as a child process, which the
iOS sandbox forbids. Only the PCL fork, which links EasyTier as a crate, is usable.

**Exactly one compile failure was iOS-specific.** `InterfaceFilter` has no iOS
implementation, and the macOS one shells out to `networksetup`, which iOS does not have.
Mobile has no way to filter interfaces, so iOS joins the Android branch (accept
everything). Everything else was dependency version drift.

**A new FFI.** Upstream exposes JNI only. But Terracotta already serves its entire control
surface over HTTP — that is what the desktop UI uses — so one native entry point suffices:

```c
uint16_t terracotta_ios_start(const char *dataDir);   // start the control server, return its port
```

Everything else is `http://127.0.0.1:<port>/state/…`. Smaller surface than hand-writing an
FFI per call, and less to break when upstream moves.

> **No TUN.** On iOS a TUN device means a Network Extension, and that entitlement cannot be
> signed with a free developer account. EasyTier's no-TUN mode applies, with its documented
> limitation: hosting works, joining needs the address entered by hand.

### LWJGL 3.4.x — `build-lwjgl-natives.sh`

Minecraft 26.2 requires 3.4.1 and 26.3 requires 3.4.3, and neither is **mixable with 3.3.3** — 3.4 introduced new callback
infrastructure (`Upcalls`, `ffi_get_closure_size`, `Callback$Descriptor`), so the Java side
and the natives must match.

The delicate part is **libffi's closure layout**. `FFI_EXEC_TRAMPOLINE_TABLE` (1 on iOS)
changes the field offsets of `ffi_closure`, and LWJGL's `ffi.h` gates that on
`defined(LWJGL_MACOS) && defined(LWJGL_arm64)` — **lowercase `arm64`**. Passing
`LWJGL_ARM64` silently selects the wrong offsets, a callback's `user_data` reads as 0, and
the game dies.

The default is **3.4.3**. The Java jars and the natives must match down to the patch
version — a 3.4.3 jar over 3.4.1 natives has no `MemoryUtil.ngetPageSize`, class
initialisation fails, and everything that touches LWJGL falls over with it.

### GLFW shims — `build-javaapp.sh` (3)

Builds the JavaApp from [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) while
filling in the surface LWJGL 3.4.1 widened: `glfwPlatformSupported`, `glfwGetMonitorName`,
and three IME/preedit callbacks.

It also closes a latent NPE. `glfwGetInputMode` unboxes the result of an empty `HashMap`
lookup directly, so **asking for any mode that was never set is an unconditional crash**.
Minecraft 26.2 asks for `GLFW_IME` (new in 3.4) every tick. Rather than special-casing IME,
the guard goes in the one function, with defaults matching real GLFW (`NORMAL` for the
cursor, `FALSE` otherwise).

From 26.3 it also adds the `ca.weblite.objc` stubs in `JavaPatches/`. The game looks only at
`os.name` ("Mac OS X") and calls into AppKit, whose JNA underside ends the boot on iOS with
`NoClassDefFoundError`. Shadowing `MacosUtil` itself collides with the client jar's
signature, so the stubs sit one level down.

### `build-spirv-cross.sh`

Minecraft 26.2's blaze3d wants `libspirv-cross`. Only the `spvc_*` C API is needed, so the
dylib exports just that.

### Windowing and input — `build-sdl3.sh` (50)

Minecraft 26.3 dropped GLFW for **SDL3**. SDL3 already has an iOS backend (uikit), so there is
no need to reimplement everything the way GLFW required. But that backend was written on the
premise that **SDL owns the app**, and inside a launcher the premise does not hold.

**① UIKit touched from the render thread (46)**

The game calls SDL from its render thread, and the uikit backend reaches into UIKit for
windows, screens, text input and shutdown. Off the main thread that either dies without a
log line or trips a FrontBoard trap. Those entry points are marshalled to the main thread
with `dispatch_sync_f`, or called directly when already there. The list is **generated by
parsing the declarations**, not written by hand.

> There was a guessing phase. The wrapped set grew 3 → 11 → 27 → 37 and the same exception
> fired at the same spot; printing a symbolicated stack with `NSSetUncaughtExceptionHandler`
> answered it in one go — `SDL_Vulkan_CreateSurface`. 26.3 renders with **Vulkan**, not GL.

**② A window size set without an event**

Window creation writes the real size straight into `window->w/h`, so the RESIZED that follows
carries the same values and gets filtered. The game starts its screen size from
`--width/--height` (854×480 by default) and only updates it on RESIZED, so it believed
854×480 forever, and touches drifted upward the lower you pressed. After the window is built,
the real size is announced once explicitly.

**③ GPU work in the background**

iOS refuses GPU work from a background app, and MoltenVK treats that as a lost device —
leaving to the home screen killed the game with `VK_ERROR_DEVICE_LOST`. The game ignores SDL's
notifications but pumps events every frame, so that thread is parked right there while the
app is inactive.

### `build-shaderc.sh`

26.3's render engine compiles GLSL to SPIR-V **at runtime**. One of the 45 entry points LWJGL
3.4.3 requires (`shaderc_compile_options_set_max_id_bound`) was missing from the older binary,
so this builds a pinned tag and checks the required symbols at the end, stopping if any is
absent.

---

## 2. Running it

### Prerequisites

```bash
brew install cmake ninja
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh   # for Terracotta
rustup target add aarch64-apple-ios
```

Xcode and the iOS SDK are required. **macOS only.**

### Building locally

```bash
git clone https://github.com/FlameLaunchers/FlameLauncher-Natives.git
cd FlameLauncher-Natives

./Scripts/build-mobileglues.sh            # renderer
./Scripts/build-terracotta.sh --release   # online LAN
./Scripts/build-spirv-cross.sh            # Minecraft 26.2
./Scripts/build-shaderc.sh                # Minecraft 26.3 shader compiler
./Scripts/build-sdl3.sh all               # Minecraft 26.3 windowing and input (iOS · Android)
./Scripts/build-lwjgl-natives.sh          # LWJGL 3.4.3 natives (iOS)
./Scripts/build-lwjgl-natives-android.sh  # LWJGL 3.4.3 natives (Android)
LWJGL_VERSION=3.4.3 ./Scripts/build-javaapp.sh   # Java stack for 26.2 and 26.3
```

Everything lands under `Runtime/`; take it into your launcher project and link it.

Terracotta pulls and compiles 641 crates, so **the first run takes 10–20 minutes.**

### Regenerating the patches

```bash
EMIT_PATCH_DIR=patches ./Scripts/build-mobileglues.sh
```

The unified diff in `patches/` is rewritten, so `git diff` shows exactly what changed when
upstream moves.

### Building in GitHub Actions

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs those same scripts on a
macOS runner.

| Trigger | When |
|---|---|
| **Manual dispatch** | Optionally pick targets (`-f targets="mobileglues terracotta"`) |
| **`v*` tags** | Zips the output and attaches it to the release |
| **Weekly schedule** | Mondays, 03:00 KST |

```bash
gh workflow run "iOS native build" -R FlameLaunchers/FlameLauncher-Natives
```

**The weekly run is the real point of this workflow.** Because every patch stands on a hard
assert, an upstream change to an anchor stops the build — and the schedule means you learn
that **the same week** rather than months later.

Two verification steps run:

1. **Confirm the output is iOS arm64.** `cargo` and `cmake` will happily **succeed with the
   wrong target.** A macOS binary slipping through is only discovered when the app fails to
   load it, so every artefact's `lipo -info` and `LC_BUILD_VERSION` (platform 2 = iOS) is
   checked, and the job fails if it does not match.
2. **Compare against the stored patches.** If the freshly generated diff differs from
   `patches/`, the job warns and prints the difference.

---

## Releases

Two independent tracks, each with its own workflow:

| Tag | Workflow | Assets |
|---|---|---|
| `sdl3-v*` | `.github/workflows/sdl3.yml` | `libSDL3-ios-arm64.dylib`, `libSDL3-android-arm64-v8a.so` |
| `lwjgl-v*` | `.github/workflows/lwjgl.yml` | `lwjgl-ios-arm64.zip`, `lwjgl-android-arm64-v8a.zip` |

Both also run on `workflow_dispatch`, where the upstream version is an input, so you can build
a different SDL or LWJGL release without touching the scripts.


## 3. Licence

**[AGPL-3.0](LICENSE).**

This repository holds no upstream source. But **a patch is a derivative of the file it
modifies** and carries that file's licence. Since this repository patches works under
several licences at once, the collection as a whole matches the strongest among them —
**Terracotta's AGPL-3.0**.

| Script | Upstream | Upstream licence |
|---|---|---|
| `build-mobileglues.sh` | [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) | LGPL-2.1-only |
| `build-terracotta.sh` | [Terracotta-lib](https://github.com/PCL-Community/Terracotta-lib) | **AGPL-3.0** |
| | [EasyTier](https://github.com/EasyTier/EasyTier) | LGPL-3.0 |
| `build-javaapp.sh` | [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS) | GPL-3.0 |
| | [LWJGL](https://github.com/LWJGL/lwjgl3) | BSD-3-Clause |
| `build-sdl3.sh` | [SDL](https://github.com/libsdl-org/SDL) | Zlib |
| `build-lwjgl-natives*.sh` | [LWJGL](https://github.com/LWJGL/lwjgl3) · [libffi](https://github.com/libffi/libffi) | BSD-3-Clause · MIT |
| `build-spirv-cross.sh` | [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) | Apache-2.0 |
| `build-shaderc.sh` | [shaderc](https://github.com/google/shaderc) · [glslang](https://github.com/KhronosGroup/glslang) · [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) | Apache-2.0 · BSD-3-Clause and others · Apache-2.0 |

If you want a single patch on its own terms: the patch to a MobileGlues file is **equally
available to you under LGPL-2.1-only**, and the patch to an Amethyst-iOS file under
GPL-3.0 — each matching the file it modifies. AGPL-3.0 applies to the collection.

Every upstream's full licence text is in [`licenses/`](licenses), verbatim.

Each patch locates its insertion point by quoting a short excerpt of the upstream file.
Those excerpts come from the repositories above and are reproduced **only to identify a
position in a file.**

See [NOTICE](NOTICE) for the details.

> Minecraft is a trademark of Mojang AB. This project is not affiliated with, endorsed by,
> or connected to Mojang AB or Microsoft.

<div align="right"><a href="#-flamelauncher-natives">⬆ Back to top</a></div>
