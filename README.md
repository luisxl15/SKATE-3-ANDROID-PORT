# Skate 3 — Android port

An Android (arm64) port of **Skate 3 Recompiled**. The Xbox 360 game is
**statically recompiled** to native code — this is not an emulator: the PowerPC
game code is translated to C++ and compiled to real aarch64, with Vulkan for
graphics and SDL3 for input, audio and windowing.

The recompilation itself, the native renderer and everything that makes the game
run are the work of the upstream project by **mchughalex**
([skate3recomp](https://github.com/mchughalex/skate3recomp)); its documentation
is kept here as [`README-Upstream.md`](README-Upstream.md). This repository adds
the Android target on top: app shell, touch controls, and the platform fixes
listed below.

> **No game files are included, and none are distributed.** You must provide
> your own legally-obtained copy of Skate 3 (Xbox 360).

## Status

| | |
|---|---|
| Boot, menus, FMV | working |
| **Gameplay** | **working** |
| On-screen touch controls | working (Xbox / PlayStation glyphs, configurable) |
| In-game settings screen | working (on-screen `ESC` button) |
| Audio | partial — the XMA decoder overruns its input buffer and recovers, so playback glitches |
| Skater portrait boxes in menus | intentionally empty (see *Known issues*) |
| Textures on GPUs without BC support | fallback implemented, **not yet verified on hardware** |

Verified on:

- **Emulator** (BlueStacks, Android 9, x86_64 with host GPU passthrough) — reaches
  gameplay at ~56 FPS. Note this renders on the *host's* desktop GPU, so it says
  nothing about mobile GPU performance.
- **Phone** — Redmi 13 (Android 15, arm64, Mali‑G52 MC2) — boots and reaches the
  menus natively. Expect low frame rates: this is a low-end mobile GPU.

## Requirements

### Device
- arm64-v8a, Android 8.0 (API 26) or newer
- Vulkan-capable GPU
- ~7 GB free storage for the game data

### Building
- Android NDK **r29**
- CMake + Ninja
- A host C++ toolchain (the code generator runs on your PC, not the phone)
- JDK 17 (for Gradle)
- Your Skate 3 dump, **plus Title Update 3**. Without the TU the code generator
  leaves unresolved calls and the build will not link.

## Building

The code generator needs `default.xex` and `default.xexp` from your dump. Their
location is set in `CMakeUserPresets.json` — point it at your own copy.

Cross-compile the native libraries:

```bash
cmake --build out/build/android-arm64 --target skate3 -j4
```

Copy the two resulting libraries into the APK's `jniLibs`:

```bash
cp out/build/android-arm64/librexruntimerd.so out/build/android-arm64/libskate3.so android/app/src/main/jniLibs/arm64-v8a/
```

Build the APK:

```bash
cd android && ./gradlew assembleDebug
```

The result is `android/app/build/outputs/apk/debug/app-debug.apk`.

## Installing

```bash
adb install -r -d app-debug.apk
```

Copy your game data to a **public** folder — from Android 11 on, `adb push`
cannot write into `Android/data`, which is why the app reads from here instead:

```bash
adb shell mkdir -p /sdcard/skate3/game
adb push game/. /sdcard/skate3/game/
```

Grant "All files access" so the app can read that folder:

```bash
adb shell appops set com.skate3recomp MANAGE_EXTERNAL_STORAGE allow
```

On Android 11+ the app also asks for this permission on first launch — accept
it, or it will close without finding the data.

The first launch is slow: shaders are compiled synchronously on purpose (see
below). Later launches reuse the cache.

## Configuration

Optional. Drop a `skate3.toml` in `/sdcard/skate3/` — `config/skate3.android.toml`
is a documented starting point.

Settings changed in the in-game screen are saved to the app's private storage
and **override** that file, so the settings screen is the source of truth once
you have used it.

Two settings are forced from `AndroidManifest.xml` because they decide whether
the game is visible at all:

- `async_shader_compilation = false` and `vulkan_async_skip_incomplete_frames = false`.
  With async compilation, frames drawn with placeholder pipelines are skipped so
  they never flash. A phone GPU compiles slowly enough that *every* frame is
  skipped — a permanently black screen. Compiling synchronously costs stutter in
  the first seconds instead.

## In-game settings

Press the on-screen **`ESC`** button (top of the screen) to open the settings.
Besides the usual graphics options, **Controls → On-Screen Buttons** configures
the touch overlay:

| Option | Values |
|---|---|
| Button Icons | Xbox / PlayStation |
| Button Style | Outline / Solid / Full |
| Button Colour | Black / White |

All three apply immediately.

## Known issues

**Skater portrait boxes are empty in menus.** Entering the team/difficulty
screens lets the game's own render-to-texture passes for character portraits
execute, and on Android those corrupt the GPU command ring buffer:

```
native-scene: portrait window - suppress mode 2 -> 3
[gpu] Unimplemented GPU OPCODE: 0x00
**** INDIRECT RINGBUFFER: Failed to execute packet
```

followed by a SIGSEGV in the render thread. `skate3_native_render_scene_menu_rtt_passes = false`
keeps those passes suppressed: the portraits stay blank, and the game reaches
gameplay.

**White squares on GPUs without BC/S3TC.** Xbox 360 textures are DXT
compressed. Desktop GPUs support BC; most mobile GPUs (Mali in particular)
expose only ETC2/ASTC, so texture creation fails and the decoder draws those
textures white — including font atlases, which turns menu text into white
blocks. A CPU decompression fallback (BC1–BC5 → RGBA8/R8/RG8) is implemented and
gated behind a runtime capability probe, so it is dormant wherever BC works.
**It has not been verified on a device that lacks BC yet.**

**Audio glitches.** The XMA decoder repeatedly reports
`input offset 16416 exceeds buffer size 16384` and recovers by swapping the
input buffer.

**Do not force these:**

- `skate3_native_render_scene_msaa` — rebuilds the native scene's whole pipeline
  family; forcing it caused in-game hangs.
- `resolution_scale` / `draw_resolution_scale_x` / `_y` — forcing them from the
  environment left the game black while still running at full frame rate. Change
  the render scale from the settings screen instead.

## Notes on the port

Things that had to change for Android, in case they help a similar port:

- **`AndroidInitialize()` was never called.** The SDK defines it for memory,
  threading and filesystem, but its upstream entry point is replaced by SDL's
  library mode. Without it `ASharedMemory_create` stays null and the ~4.8 GB
  guest heap silently falls back to a memfd — tmpfs pages that cannot be purged,
  which took a 4 GB device down with the whole system.
- **The config was never read.** `GetAppRootFolder()` derives from
  `/proc/self/exe`, which on Android is the zygote in `/system/bin` — read-only.
  It now looks in `/sdcard/skate3` first.
- **Fibers.** Bionic has no `getcontext`/`makecontext`/`swapcontext`, so
  [libucontext](https://github.com/kaniini/libucontext) is vendored for aarch64.
- **The Back button.** SDL finishes the activity on Back by default, which kills
  the process and loses all progress. `SDL_ANDROID_TRAP_BACK_BUTTON=1` delivers
  it to the app instead. (On emulators the host's Esc key is mapped to Back.)

## Credits

- **[mchughalex/skate3recomp](https://github.com/mchughalex/skate3recomp)** — the
  recompilation and the native renderer, i.e. the project this is a port of. Its
  documentation is preserved as [`README-Upstream.md`](README-Upstream.md).
- [rexglue-sdk](https://github.com/mchughalex/skate3recomp) — the Xbox 360 static
  recompilation runtime, derived from [Xenia](https://xenia.jp/).
- [SansNope/UnleashedRecomp-Android](https://github.com/SansNope/UnleashedRecomp-Android)
  — the Android app shell this port started from, and the origin of the touch
  controls overlay.
- [Buku313/Skate3-Android](https://github.com/Buku313/Skate3-Android) — an
  independent Android port of the same game. Its published cvar configuration is
  what identified the async-shader cause of the black screen here.
- Controller button icons: **PS5 / Xbox Series Button Icons and Controls** by
  **Zacksly** — <https://zacksly.itch.io> — licensed
  [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/). Used unmodified;
  only a subset was repackaged into `android/app/src/main/assets/buttons/`.

## Legal

This repository contains no game code or assets. Skate 3 is © Electronic Arts.
You need your own legally-obtained copy to build or run anything here.
