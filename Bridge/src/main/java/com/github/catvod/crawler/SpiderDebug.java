package com.github.catvod.crawler;

import android.content.Context;

/** Minimal host context bridge expected by CatVod's guarded Spider runtime. */
public final class SpiderDebug {
    public static Context context;

    private SpiderDebug() {}

    public static void init(Context value) { context = value; }

    public static Context getContext() { return context; }

    public static void log(Throwable error) {
        if (error != null) android.util.Log.w("TVBoxSpider", error.toString(), error);
    }

    public static void log(String message) {
        android.util.Log.d("TVBoxSpider", message == null ? "" : message);
    }
}
