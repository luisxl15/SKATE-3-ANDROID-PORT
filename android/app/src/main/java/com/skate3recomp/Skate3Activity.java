package com.skate3recomp;

import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.Settings;
import android.widget.Toast;

import org.libsdl.app.SDLActivity;

/**
 * Skate 3 (recompiled) Android activity.
 *
 * Loads the native runtime (which links SDL3 statically and provides SDL's JNI
 * glue) followed by the recompiled game library. The last entry is the "main
 * shared object": SDL resolves SDL_main() from it, which our src/main_android.cpp
 * defines to look up and run the app registered under "skate3".
 *
 * The game data lives in /sdcard/skate3/game and is read directly, which needs
 * the "All files access" (MANAGE_EXTERNAL_STORAGE) permission on Android 11+.
 * We gate startup on that permission so the game never launches without data.
 */
public class Skate3Activity extends SDLActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                && !Environment.isExternalStorageManager()) {
            Toast.makeText(this,
                    "Conceda 'Acesso a todos os arquivos' ao Skate 3 e reabra o app.",
                    Toast.LENGTH_LONG).show();
            try {
                Intent intent = new Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } catch (Exception e) {
                startActivity(new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION));
            }
            finish();
            return;
        }
        super.onCreate(savedInstanceState);
    }

    @Override
    protected String[] getLibraries() {
        return new String[]{
            "rexruntimerd", // runtime + SDL3 (RelWithDebInfo build -> "rd" suffix)
            "skate3",       // recompiled game; exports SDL_main
        };
    }
}
