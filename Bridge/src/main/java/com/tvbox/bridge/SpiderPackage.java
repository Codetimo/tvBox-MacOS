package com.tvbox.bridge;

import android.content.Context;
import android.os.Build;
import dalvik.system.DexClassLoader;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.util.Locale;

/** Downloads, verifies, and prepares one remote Spider package for DexClassLoader. */
final class SpiderPackage {
    private final File file;
    private final File nativeDirectory;
    private ClassLoader loader;
    private Exception initializationError;
    private final java.util.Map<String, String> cookieDigests = new java.util.HashMap<>();
    private final java.util.Map<String, LoginTask> loginTasks = new java.util.HashMap<>();
    private final java.util.Map<String, Long> completedLoginVersions = new java.util.HashMap<>();
    private static final java.util.concurrent.ScheduledExecutorService LOGIN_EXPIRY =
            java.util.concurrent.Executors.newSingleThreadScheduledExecutor(runnable -> {
                Thread thread = new Thread(runnable, "tvbox-qr-expiry");
                thread.setDaemon(true);
                return thread;
            });

    private static final class LoginTask {
        final String id;
        final Method proxy;
        final long cookieVersion;
        java.util.concurrent.ScheduledFuture<?> expiry;
        LoginTask(String id, Method proxy, long cookieVersion) { this.id = id; this.proxy = proxy; this.cookieVersion = cookieVersion; }
    }

    /** Expose only the supported QR actions and bind task IDs to this package and provider. */
    synchronized org.json.JSONObject panLogin(Context context, String provider, String action, String taskId, long cookieVersion) throws Exception {
        if (!("quark".equals(provider) || "baidu".equals(provider))) throw new IllegalArgumentException("invalid provider");
        if (!("start".equals(action) || "poll".equals(action) || "cancel".equals(action))) throw new IllegalArgumentException("invalid action");
        LoginTask task = loginTasks.get(provider);
        if ("start".equals(action)) {
            cancelLogin(provider, task);
            ClassLoader current = initializedLoader(context);
            Class<?> config;
            try { config = current.loadClass("com.github.catvod.spider.PanConfigGuard"); }
            catch (ClassNotFoundException ignored) { return loginStatus("unsupported", true); }
            Object instance = config.getDeclaredConstructor().newInstance();
            config.getMethod("init", Context.class, String.class).invoke(instance, context, "");
            Method proxy = current.loadClass("com.github.catvod.spider.Init").getMethod("proxyInvoke", java.util.Map.class);
            org.json.JSONObject result = configurationJSON(proxy, loginParams(provider, "loginStart", ""));
            if (result.optInt("code", -1) != 0) throw new IOException("QR start rejected");
            String id = result.optString("taskId", "");
            String qr = result.optString("qrUrl", "");
            if (id.isEmpty() || id.length() > 512 || qr.isEmpty() || qr.length() > 1024 * 1024) {
                throw new IOException("invalid QR response");
            }
            LoginTask created = new LoginTask(id, proxy, cookieVersion);
            loginTasks.put(provider, created);
            // Even a client that closes during start cannot leave a live login task indefinitely.
            created.expiry = LOGIN_EXPIRY.schedule(() -> {
                synchronized (SpiderPackage.this) {
                    if (loginTasks.get(provider) == created) cancelLogin(provider, created);
                }
            }, 5, java.util.concurrent.TimeUnit.MINUTES);
            return loginStatus("waiting", false).put("taskId", id).put("qrUrl", qr);
        }
        if (task == null || !task.id.equals(taskId)) return loginStatus("expired", true);
        if ("cancel".equals(action)) {
            cancelLogin(provider, task);
            return loginStatus("cancelled", true);
        }
        org.json.JSONObject result = configurationJSON(task.proxy, loginParams(provider, "loginPoll", task.id));
        String status = result.optString("status", "waiting");
        if ("success".equals(status)) {
            java.util.Map<String, String> params = new java.util.HashMap<>();
            params.put("do", "pan"); params.put("action", "credentials");
            String cookie = configurationJSON(task.proxy, params).optString(provider + "Cookie", "");
            if (cookie.isEmpty() || cookie.indexOf('\r') >= 0 || cookie.indexOf('\n') >= 0) throw new IOException("invalid login credentials");
            // Protect the newly written credentials from in-flight old snapshots. The digest must
            // reflect the new value so a later explicit logout still clears the package's cookie.
            loginTasks.remove(provider);
            if (task.expiry != null) task.expiry.cancel(false);
            completedLoginVersions.put(provider, Math.max(task.cookieVersion, cookieVersion));
            cookieDigests.put(provider, sha256(cookie));
            return loginStatus("success", true).put("cookie", cookie);
        }
        boolean terminal = result.optBoolean("terminal", false);
        if ("expired".equals(status) || "cancelled".equals(status) || "error".equals(status)) terminal = true;
        if (terminal) {
            cancelLogin(provider, task);
            return loginStatus("expired".equals(status) ? "expired" : "error", true);
        }
        return loginStatus("scanned".equals(status) ? "scanned" : "waiting", false);
    }

    /** Build fixed, non-sensitive statuses rather than returning third-party messages. */
    private static org.json.JSONObject loginStatus(String status, boolean terminal) throws Exception {
        return new org.json.JSONObject().put("status", status).put("terminal", terminal);
    }

    /** Only these internal callers choose the configuration action; callers cannot invoke arbitrary proxy operations. */
    private static java.util.Map<String, String> loginParams(String provider, String action, String taskId) {
        java.util.Map<String, String> params = new java.util.HashMap<>();
        params.put("do", "pan"); params.put("action", action); params.put("provider", provider);
        if (!taskId.isEmpty()) params.put("taskId", taskId);
        return params;
    }

    /** Remove local access immediately, then best-effort cancel the remote login without logging its response. */
    private void cancelLogin(String provider, LoginTask task) {
        if (task == null) return;
        loginTasks.remove(provider);
        if (task.expiry != null) task.expiry.cancel(false);
        try { configurationJSON(task.proxy, loginParams(provider, "loginCancel", task.id)); }
        catch (Exception ignored) { /* Local task is already inaccessible and the remote QR expires. */ }
    }

    /** Sync through the package's own configuration API, whose keys are verified against its web UI. */
    synchronized boolean synchronizeCookies(Context context, org.json.JSONObject cookies, long version) throws Exception {
        if (cookies == null || cookies.length() == 0) return false;
        boolean needsUpdate = false;
        for (String provider : new String[] {"quark", "baidu"}) {
            Long completedVersion = completedLoginVersions.get(provider);
            if (completedVersion != null && version <= completedVersion) {
                // Reject stale changed credentials before a site constructor can receive its old ext.
                if (cookies.has(provider) && !sha256(cookies.getString(provider)).equals(cookieDigests.get(provider))) {
                    throw new IllegalStateException("网盘登录信息已更新，请重试当前操作。");
                }
                continue;
            }
            if (cookies.has(provider) && !sha256(cookies.getString(provider)).equals(cookieDigests.get(provider))) needsUpdate = true;
        }
        if (!needsUpdate) return false;
        ClassLoader current = initializedLoader(context);
        Class<?> config;
        try { config = current.loadClass("com.github.catvod.spider.PanConfigGuard"); }
        catch (ClassNotFoundException ignored) { return false; } // Other packages consume their own ext format.
        Object instance = config.getDeclaredConstructor().newInstance();
        config.getMethod("init", Context.class, String.class).invoke(instance, context, "");
        Class<?> init = current.loadClass("com.github.catvod.spider.Init");
        Method proxy = init.getMethod("proxyInvoke", java.util.Map.class);
        boolean changed = false;
        for (String provider : new String[] {"quark", "baidu"}) {
            if (!cookies.has(provider)) continue; // Absence leaves source-managed credentials alone.
            Long completedVersion = completedLoginVersions.get(provider);
            if (completedVersion != null && version <= completedVersion) continue;
            String value = cookies.getString(provider);
            String digest = sha256(value);
            if (digest.equals(cookieDigests.get(provider))) continue;
            String title = provider.equals("quark") ? "Quark" : "Baidu";
            java.util.Map<String, String> params = new java.util.HashMap<>();
            params.put("do", "pan");
            params.put("action", (value.isEmpty() ? "clear" : "set") + title + "Cookie");
            params.put("value", value);
            // Never propagate package exceptions: third-party messages may contain submitted credentials.
            try {
                org.json.JSONObject result = configurationJSON(proxy, params);
                if (result.optInt("code", -1) != 0) throw new IOException("configuration rejected");
                params.clear();
                params.put("do", "pan"); params.put("action", "credentials");
                String stored = configurationJSON(proxy, params).optString(provider + "Cookie", "");
                if (!value.equals(stored)) throw new IOException("configuration readback mismatch");
            } catch (Exception error) {
                throw new IOException("网盘 Cookie 同步失败，请更新站源或重新登录（" + provider + "）。");
            }
            cookieDigests.put(provider, digest);
            changed = true;
        }
        return changed;
    }

    /** Consume a bounded UTF-8 configuration response without logging its sensitive contents. */
    private static org.json.JSONObject configurationJSON(Method proxy, java.util.Map<String, String> params) throws Exception {
        Object[] result = (Object[]) proxy.invoke(null, params);
        if (result == null || result.length < 3 || !(result[2] instanceof InputStream)) {
            throw new IOException("invalid configuration response");
        }
        try (InputStream input = (InputStream) result[2];
             java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() + count > 2 * 1024 * 1024) throw new IOException("configuration response too large");
                output.write(buffer, 0, count);
            }
            if (!(result[0] instanceof Number) || ((Number) result[0]).intValue() != 200) {
                throw new IOException("configuration HTTP failure");
            }
            return new org.json.JSONObject(output.toString("UTF-8"));
        }
    }

    private SpiderPackage(File file, File nativeDirectory) {
        this.file = file;
        this.nativeDirectory = nativeDirectory;
    }

    File file() { return file; }
    File nativeDirectory() { return nativeDirectory; }

    /** One loader and Init invocation per package: native state must not be recreated per site. */
    synchronized ClassLoader initializedLoader(Context context) throws Exception {
        if (initializationError != null) throw initializationError;
        if (loader != null) return loader;
        try {
            // Keep optimized DEX output inside its immutable version so cold eviction reclaims it too.
            File optimized = new File(file.getParentFile(), "optimized");
            if (!optimized.exists() && !optimized.mkdirs()) throw new IOException("cannot create dex cache");
            ClassLoader candidate = new DexClassLoader(file.getAbsolutePath(), optimized.getAbsolutePath(),
                    nativeDirectory.getAbsolutePath(), context.getClassLoader());
            // Native libraries must be loaded by their owning package, not the host ClassLoader.
            Class<?> init = null;
            try { init = candidate.loadClass("com.github.catvod.spider.Init"); }
            catch (ClassNotFoundException ignored) { /* Optional CatVod hook. */ }
            if (init != null) {
                Method hook = null;
                try { hook = init.getMethod("init", Context.class); }
                catch (NoSuchMethodException ignored) { /* Per-spider init only. */ }
                if (hook != null) hook.invoke(null, context.getApplicationContext());
                // Guard packages call JNI with this loader without checking for null.
                // Fail in Java before a constructor can abort the entire bridge process.
                Method nativeLoader = null;
                try { nativeLoader = init.getMethod("loader"); }
                catch (NoSuchMethodException ignored) { /* Unprotected packages have no loader hook. */ }
                if (nativeLoader != null && Modifier.isStatic(nativeLoader.getModifiers())
                        && ClassLoader.class.isAssignableFrom(nativeLoader.getReturnType())
                        && nativeLoader.invoke(null) == null) {
                    throw new IOException("Spider 包初始化失败：内部 ClassLoader 为空，已阻止调用 JNI，请更新该站源的 Spider 包。");
                }
            }
            loader = candidate;
            return loader;
        } catch (Exception error) {
            initializationError = error;
            throw error;
        } catch (LinkageError error) {
            initializationError = new IOException("Spider 包与当前 Android 运行环境不兼容", error);
            throw initializationError;
        }
    }

    /** Download mutable URLs on revalidation; archive and native paths are immutable content versions. */
    static SpiderPackage prepare(Context context, String url, String expectedMd5) throws Exception {
        String preferred = Build.SUPPORTED_ABIS != null && Build.SUPPORTED_ABIS.length > 0
                ? Build.SUPPORTED_ABIS[0] : "arm64-v8a";
        PackageCache.Prepared prepared = PackageCache.prepare(new File(context.getCodeCacheDir(), "tvbox-spider"),
                url, expectedMd5, preferred);
        return new SpiderPackage(prepared.archive, prepared.nativeDirectory);
    }

    /** Keep the active QR task attached to its current loader until it completes or expires. */
    synchronized boolean hasPendingLogin() { return !loginTasks.isEmpty(); }

    static String normalizeMd5(String value) {
        if (value == null) return null;
        String normalized = value.trim().toLowerCase(Locale.US);
        return normalized.matches("[0-9a-f]{32}") ? normalized : null;
    }

    static String md5(File file) throws Exception { return digest(file, "MD5"); }

    private static String sha256(String text) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] bytes = digest.digest(text.getBytes("UTF-8"));
        return hex(bytes);
    }

    private static String digest(File file, String algorithm) throws Exception {
        MessageDigest digest = MessageDigest.getInstance(algorithm);
        try (InputStream input = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buffer = new byte[32 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format(Locale.US, "%02x", value & 0xff));
        return result.toString();
    }

}
