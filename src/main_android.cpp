// Android entry point for the recompiled Skate 3.
//
// On Android the game ships as a shared library and runs in library mode
// (XE_UI_WINDOWED_APPS_IN_LIBRARY): SDL's activity loads the library and calls
// SDL_main. main.cpp registers the app under the identifier "skate3" via
// REX_DEFINE_APP; here we look it up in the windowed-app registry and run it
// through the SDL windowed-app context, mirroring windowed_app_main_sdl.cpp.
//
// Including <SDL3/SDL_main.h> makes SDL rewrite main() into SDL_main() and
// supply the real JNI entry that the Android activity invokes.

#include <algorithm>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <rex/cvar.h>
#include <rex/filesystem.h>
#include <rex/logging.h>
#include <rex/memory/utils.h>
#include <rex/thread.h>
#include <rex/ui/windowed_app.h>
#include <rex/ui/windowed_app_context_sdl.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#if defined(__ANDROID__)
#include <unistd.h>
#include <android/log.h>
#define SK3DBG(...) __android_log_print(ANDROID_LOG_INFO, "SK3DBG", __VA_ARGS__)
#else
#define SK3DBG(...) ((void)0)
#endif

int main(int argc, char** argv) {
  SK3DBG("main() entry argc=%d", argc);
#if defined(__ANDROID__)
  // The process working directory on Android is the read-only /system/bin;
  // anything that writes relative to current_path() (logs, cvars, caches) would
  // fail there. Switch to the app's private writable storage up front.
  if (const char* internal_storage = SDL_GetAndroidInternalStoragePath()) {
    (void)chdir(internal_storage);
    SK3DBG("chdir to internal_storage=%s", internal_storage);
    // GetUserFolder() (config/cache/saves/DLC) follows XDG_DATA_HOME, then
    // $HOME/.local/share — which resolves to the read-only /data/.local on
    // Android. Point it at the app's private writable storage instead.
    setenv("XDG_DATA_HOME", internal_storage, 1);
  } else {
    SK3DBG("SDL_GetAndroidInternalStoragePath returned null");
  }

  // Android-only late binding of libc/libandroid entry points (upstream calls
  // these from its own Android entry point, which library mode replaces).
  // Without them rex::memory has no ASharedMemory_create and silently falls
  // back to a memfd for the ~4.8GB guest heap: memfd pages are tmpfs and
  // cannot be purged, which took a 4GB device down with the whole system.
  rex::memory::AndroidInitialize();
  rex::thread::AndroidInitialize();
  rex::filesystem::AndroidInitialize();
  SK3DBG("Android subsystems initialized");
#endif

  auto remaining = rex::cvar::Init(argc, argv);
  rex::cvar::ApplyEnvironment();
  SK3DBG("cvar init done");
  rex::InitLoggingEarly();
  SK3DBG("InitLoggingEarly done");

  if (!SDL_Init(SDL_INIT_VIDEO)) {
    SK3DBG("SDL_Init(VIDEO) FAILED: %s", SDL_GetError());
    REXLOG_ERROR("Failed to initialize SDL video: {}", SDL_GetError());
    return EXIT_FAILURE;
  }
  SK3DBG("SDL_Init(VIDEO) ok");

  int result = EXIT_FAILURE;
  {
    rex::ui::WindowedApp::Creator creator = rex::ui::WindowedApp::GetCreator("skate3");
    if (!creator) {
      SK3DBG("GetCreator('skate3') returned null");
      REXLOG_ERROR("No windowed app registered under identifier 'skate3'");
      SDL_Quit();
      return EXIT_FAILURE;
    }
    SK3DBG("creator ok, creating app");

    rex::ui::SDLWindowedAppContext app_context;
    std::unique_ptr<rex::ui::WindowedApp> app = creator(app_context);

    const auto& option_names = app->GetPositionalOptions();
    std::map<std::string, std::string> parsed;
    size_t count = std::min(remaining.size(), option_names.size());
    for (size_t i = 0; i < count; ++i) {
      parsed[option_names[i]] = remaining[i];
    }
    app->SetParsedArguments(std::move(parsed));

    SK3DBG("calling OnInitialize");
    bool initialized = app->OnInitialize();
    SK3DBG("OnInitialize returned %d; entering main loop", initialized ? 1 : 0);
    result = initialized ? app_context.RunMainLoop() : EXIT_FAILURE;
    SK3DBG("main loop exited, result=%d", result);
    app->InvokeOnDestroy();
  }

  rex::ShutdownLogging();
  SDL_Quit();
  return result;
}
