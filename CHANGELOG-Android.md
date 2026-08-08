# Changelog — Android port

## Unreleased

First version that reaches gameplay on Android.

### Added
- Android target: `skate3` builds as a shared library, loaded by an SDL activity
  (`android/`), with `src/main_android.cpp` as the entry point.
- On-screen touch controls: two sticks, face buttons, d-pad, shoulders,
  triggers, Start/Back, driving an SDL virtual gamepad.
- Button artwork with Xbox and PlayStation glyph sets, configurable from the
  in-game settings screen (**Controls → On-Screen Buttons**): icon set, style
  (outline/solid/full) and colour.
- On-screen `ESC` button that opens the settings screen. It injects a real
  keyboard event, so every Escape binding behaves as it does on desktop.
- On-screen FPS counter.
- `config/skate3.android.toml`: documented configuration for mobile GPUs, read
  from `/sdcard/skate3/skate3.toml`.
- CPU decompression of BC1–BC5 textures for GPUs without BC/S3TC support, behind
  a runtime capability probe. Dormant where BC works. **Not yet verified on a
  device that lacks BC.**

### Fixed
- **Permanent black screen.** Frames drawn with placeholder pipelines were
  skipped while shaders compiled asynchronously; on a phone GPU that is every
  frame. Shader compilation is now synchronous on Android
  (`async_shader_compilation=false`, `vulkan_async_skip_incomplete_frames=false`).
- **Whole system taken down on 4 GB devices.** `rex::memory::AndroidInitialize()`
  was never called, so `ASharedMemory_create` stayed null and the ~4.8 GB guest
  heap always fell back to a memfd — tmpfs pages that cannot be purged. The
  Android initialisers for memory, threading and filesystem now run at startup.
- **Configuration was never loaded.** `GetAppRootFolder()` derives from
  `/proc/self/exe`, which on Android is the zygote in read-only `/system/bin`.
  It now resolves to `/sdcard/skate3`, falling back to the app's private storage.
- **Freeze entering the team/difficulty menus.** The game's portrait
  render-to-texture passes corrupted the GPU command ring buffer
  (`Unimplemented GPU OPCODE: 0x00`), followed by a SIGSEGV in the render thread.
  Suppressed via `skate3_native_render_scene_menu_rtt_passes=false`; the portrait
  boxes stay empty.
- **Back button closed the game.** SDL finishes the activity on Back by default,
  killing the process and losing all progress.
  `SDL_ANDROID_TRAP_BACK_BUTTON=1` delivers it to the app instead.
- **Log flood.** "Too few processor cores" was emitted on every guest thread
  reschedule — tens of thousands of lines a minute on a 4-core device, enough to
  evict the boot log from logcat. Now logged once.
- Vulkan device requirements relaxed for mobile GPUs: `vertexPipelineStoresAndAtomics`,
  `geometryShader` and `fillModeNonSolid` no longer abort initialisation.
- Landscape orientation locked, so the swapchain stops churning between
  portrait and landscape.
- Fibers on Bionic (no `getcontext`/`makecontext`/`swapcontext`) via a vendored
  `libucontext`.
- Game data is read from the public `/sdcard/skate3/game`, since Android 11+
  blocks `adb push` into `Android/data`.

### Known issues
See *Known issues* in [`README-Android.md`](README-Android.md). In short: audio
glitches (XMA decoder), empty portrait boxes in menus, and white textures on
GPUs without BC until the fallback is verified.

### Do not force
- `skate3_native_render_scene_msaa` — rebuilds the native scene's pipeline
  family; forcing it caused in-game hangs.
- `resolution_scale` / `draw_resolution_scale_x` / `_y` — forcing them from the
  environment left the game black at full frame rate. Use the settings screen.
