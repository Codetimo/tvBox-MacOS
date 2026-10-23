package com.github.catvod.crawler;

import android.content.Context;

/** Minimal host context bridge expected by CatVod's guarded Spider runtime. */
public final class SpiderDebug {
    public static Context context;

    private SpiderDebug() {}

    public static void init(Context value) { context = value; }

    public static Context getContext() { return context; }

    /** Provider stack traces can include signed URLs or cookies; retain only the failure type. */
    public static void log(Throwable error) {
        if (error != null) android.util.Log.w("TVBoxSpider", "provider_error=" + error.getClass().getSimpleName());
    }

    /** Unstructured provider messages cannot be reliably redacted; structured Bridge logs carry diagnostics. */
    public static void log(String message) {
        // Intentionally suppress raw third-party text, which may contain credentials.
    }
}
