package com.tvbox.bridge;

import android.app.Service;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.Intent;
import android.os.IBinder;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.security.SecureRandom;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Lifecycle owner for the local Spider bridge. The host starts this service
 * with ACTION_START and stops it when its own application session ends.
 * Binding is deliberately unnecessary: all calls use authenticated loopback
 * HTTP so a macOS host can use the same protocol as an Android host.
 */
public final class SpiderBridgeService extends Service {
    public static final String ACTION_START = "com.tvbox.bridge.START";
    public static final String EXTRA_URL = "spider_url";
    public static final String EXTRA_MD5 = "spider_md5";
    public static final String EXTRA_CLASS = "spider_class";
    public static final String EXTRA_EXTEND = "spider_ext";
    public static final String EXTRA_PORT = "port";
    public static final String EXTRA_TOKEN = "token";
    private static final int DEFAULT_PORT = 19190;

    private final ExecutorService loader = Executors.newSingleThreadExecutor();
    private final Map<String, SpiderEngine> engines = new ConcurrentHashMap<>();
    private final Map<String, SpiderPackage> packages = new ConcurrentHashMap<>();
    // Aliases and MD5 variants for identical bytes must share the native-owning ClassLoader.
    private final Map<String, SpiderPackage> contentPackages = new ConcurrentHashMap<>();
    private volatile BridgeHttpServer server;
    private volatile SpiderPackage spiderPackage;
    private volatile String packageUrl = "";
    private volatile String defaultClass = "";
    private volatile String defaultExtend = "";
    private volatile String token = "";
    private volatile int port = DEFAULT_PORT;
    private volatile String state = "starting";
    private final java.util.concurrent.atomic.AtomicLong latestCookieVersion = new java.util.concurrent.atomic.AtomicLong(-1);
    private final Map<String, Object> packageLocks = new ConcurrentHashMap<>();
    private final Map<String, Long> packageChecks = new ConcurrentHashMap<>();
    private static final long PACKAGE_RECHECK_MILLIS = 5 * 60 * 1000L;
    private volatile String lastError = "";
    private volatile boolean restartRequired;
    private final java.util.concurrent.atomic.AtomicInteger constructedEngines = new java.util.concurrent.atomic.AtomicInteger();
    private static final java.util.concurrent.atomic.AtomicBoolean CACHE_INITIALIZED = new java.util.concurrent.atomic.AtomicBoolean();
    private static final int MAX_PACKAGE_ALIASES = 256, MAX_ENGINES = 512;

    @Override public void onCreate() {
        super.onCreate();
        // Android 8+ requires a foreground notification for this exported
        // long-lived service when macOS starts it through adb.
        if (android.os.Build.VERSION.SDK_INT >= 26) {
            NotificationChannel channel = new NotificationChannel(
                    "tvbox-spider", "TVBox Spider", NotificationManager.IMPORTANCE_LOW);
            NotificationManager manager = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (manager != null) manager.createNotificationChannel(channel);
            Notification notification = new Notification.Builder(this, "tvbox-spider")
                    .setContentTitle("TVBox Spider")
                    .setContentText("本地 Spider 服务运行中")
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setOngoing(true)
                    .build();
            startForeground(19190, notification);
        }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) { stopSelf(); return START_NOT_STICKY; }
        if (!ACTION_START.equals(intent.getAction()) && intent.getAction() != null) return START_NOT_STICKY;
        if (server != null) return START_REDELIVER_INTENT;
        packageUrl = intent.getStringExtra(EXTRA_URL);
        String md5 = intent.getStringExtra(EXTRA_MD5);
        defaultClass = trim(intent.getStringExtra(EXTRA_CLASS));
        defaultExtend = trim(intent.getStringExtra(EXTRA_EXTEND));
        port = clampPort(intent.getIntExtra(EXTRA_PORT, DEFAULT_PORT));
        token = trim(intent.getStringExtra(EXTRA_TOKEN));
        if (token.isEmpty()) token = randomToken();
        loader.execute(() -> startBridge(md5));
        // A sticky null Intent loses the token/port and leaves a foreground service
        // without an HTTP listener after native crashes. Redeliver session arguments.
        return START_REDELIVER_INTENT;
    }

    private void startBridge(String md5) {
        try {
            // Service recreation can retain native libraries; only a fresh Android process may prune files.
            if (CACHE_INITIALIZED.compareAndSet(false, true)) {
                PackageCache.cleanupColdCache(new File(getCodeCacheDir(), "tvbox-spider"));
            }
            // The macOS launcher starts the service before it knows which
            // source the user will search. In that mode package download is
            // deferred until the first request carrying `spider`/`md5`.
            if (packageUrl != null && !packageUrl.trim().isEmpty()) {
                state = "downloading";
                spiderPackage = packageFor(packageUrl + "\u0000" + trim(md5), packageUrl, md5);
            }
            server = new BridgeHttpServer(port, token, this::status, this::engineFor, this::panLogin);
            server.start();
            state = "ready";
            Log.i("TVBoxBridge", "Spider bridge listening on 127.0.0.1:" + port);
        } catch (Exception error) {
            state = "error";
            lastError = error.getClass().getSimpleName();
            Log.e("TVBoxBridge", "Spider bridge failed to start: " + lastError);
        }
    }

    /** Serialize package state only: downloads and constructors for unrelated packages remain independent. */
    private SpiderEngine engineFor(JSONObject request) throws Exception {
        String requestedURL = trim(request.optString(EXTRA_URL, request.optString("spider", "")));
        String requestedMd5 = trim(request.optString(EXTRA_MD5, request.optString("md5", "")));
        if (requestedURL.isEmpty()) requestedURL = packageUrl;
        if (requestedURL == null || requestedURL.isEmpty()) throw new IllegalStateException("spider_url is required");
        String packageKey = requestedURL + "\u0000" + requestedMd5;
        synchronized (packageLockFor(packageKey)) {
            validateCookieVersion(request);
            SpiderPackage pack = packageFor(packageKey, requestedURL, requestedMd5);
            synchronized (pack) {
                validateCookieVersion(request); // A concurrent package may have advanced credentials during download.
                if (pack.synchronizeCookies(this, request.optJSONObject("pan_cookies"), request.optLong("pan_cookie_version", -1))) {
                    // Recreate cached site instances after account changes; otherwise they may retain old auth state.
                    final String prefix = pack.file().getAbsolutePath() + "\u0000";
                    for (String cachedKey : engines.keySet()) if (cachedKey.startsWith(prefix)) engines.remove(cachedKey);
                }
                String className = trim(request.optString(EXTRA_CLASS,
                        request.optString("spiderClass", request.optString("spider_class", defaultClass))));
                String extend = request.has(EXTRA_EXTEND) ? request.optString(EXTRA_EXTEND, "") :
                        request.optString("ext", defaultExtend);
                if (className.isEmpty()) throw new IllegalArgumentException("spider_class is required");
                String key = pack.file().getAbsolutePath() + "\u0000" + className + "\u0000" + extend;
                SpiderEngine existing = engines.get(key);
                if (existing != null) return existing;
                if (constructedEngines.incrementAndGet() > MAX_ENGINES) {
                    constructedEngines.decrementAndGet();
                    throw requireRecovery();
                }
                // A failed constructor can have created native state too; retain its session budget.
                existing = SpiderEngine.load(this, pack, className, extend);
                engines.put(key, existing);
                return existing;
            }
        }
    }

    /** Resolve a QR login package without syncing old cookies or constructing a video site. */
    private JSONObject panLogin(JSONObject request) throws Exception {
        String requestedURL = trim(request.optString(EXTRA_URL, request.optString("spider", "")));
        String requestedMd5 = trim(request.optString(EXTRA_MD5, request.optString("md5", "")));
        if (requestedURL.isEmpty()) requestedURL = packageUrl;
        if (requestedURL == null || requestedURL.isEmpty()) throw new IllegalArgumentException("spider_url is required");
        String packageKey = requestedURL + "\u0000" + requestedMd5;
        synchronized (packageLockFor(packageKey)) {
            SpiderPackage pack = packageFor(packageKey, requestedURL, requestedMd5);
            synchronized (pack) {
                JSONObject result = pack.panLogin(this, request.optString("provider", ""),
                        request.optString("action", ""), request.optString("taskId", ""),
                        Math.max(latestCookieVersion.get(), request.optLong("pan_cookie_version", -1)));
                if ("success".equals(result.optString("status"))) {
                    final String prefix = pack.file().getAbsolutePath() + "\u0000";
                    for (String cachedKey : engines.keySet()) if (cachedKey.startsWith(prefix)) engines.remove(cachedKey);
                }
                return result;
            }
        }
    }

    /** Check versions atomically without retaining a service-wide lock across third-party calls. */
    private void validateCookieVersion(JSONObject request) {
        if (!request.has("pan_cookies")) return;
        long version = request.optLong("pan_cookie_version", -1);
        while (true) {
            long previous = latestCookieVersion.get();
            if (version < 0 || version < previous) throw new IllegalStateException("网盘登录信息已更新，请重试当前操作。");
            if (latestCookieVersion.compareAndSet(previous, version)) return;
        }
    }

    /** Revalidate mutable URLs periodically; retain loader/login state when bytes have not changed. Caller holds package lock. */
    private SpiderPackage packageFor(String key, String url, String md5) throws Exception {
        SpiderPackage current = packages.get(key);
        long now = android.os.SystemClock.elapsedRealtime();
        long checked = packageChecks.getOrDefault(key, 0L);
        if (current == null || (SpiderPackage.normalizeMd5(md5) == null && now - checked >= PACKAGE_RECHECK_MILLIS
                && !current.hasPendingLogin())) {
            SpiderPackage prepared;
            try { prepared = SpiderPackage.prepare(this, url, md5); }
            catch (PackageCache.CapacityException capacity) { throw requireRecovery(); }
            SpiderPackage canonical = contentPackages.putIfAbsent(prepared.file().getAbsolutePath(), prepared);
            current = canonical == null ? prepared : canonical;
            packages.put(key, current);
            packageChecks.put(key, now);
        }
        return current;
    }

    /** Bound aliases/locks before allocation without serializing network or third-party execution. */
    private Object packageLockFor(String key) throws PackageCache.CapacityException {
        synchronized (packageLocks) {
            Object existing = packageLocks.get(key);
            if (existing != null) return existing;
            if (packageLocks.size() >= MAX_PACKAGE_ALIASES) throw requireRecovery();
            Object created = new Object();
            packageLocks.put(key, created);
            return created;
        }
    }

    /** Ask the host to force-stop this process before reclaiming loaders, threads or native cache files. */
    private PackageCache.CapacityException requireRecovery() {
        restartRequired = true;
        return new PackageCache.CapacityException();
    }

    private JSONObject status() {
        JSONObject result = new JSONObject();
        try {
            result.put("ok", "ready".equals(state));
            result.put("ready", "ready".equals(state));
            result.put("restartRequired", restartRequired);
            result.put("loadedPackageVersions", contentPackages.size());
            result.put("constructedEngines", constructedEngines.get());
            result.put("engine", "android-dex");
            result.put("state", state);
            result.put("port", port);
            result.put("loopback", true);
            result.put("packageConfigured", packageUrl != null && !packageUrl.isEmpty());
            result.put("spiderClass", defaultClass);
            if (!lastError.isEmpty()) result.put("error", lastError);
        } catch (Exception ignored) {}
        return result;
    }

    @Override public void onDestroy() {
        BridgeHttpServer current = server;
        server = null;
        if (current != null) current.stop();
        loader.shutdownNow();
        engines.clear();
        packages.clear();
        contentPackages.clear();
        state = "stopped";
        stopForeground(true);
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) { return null; }

    private static String trim(String value) { return value == null ? "" : value.trim(); }

    private static int clampPort(int value) { return value > 0 && value <= 65535 ? value : DEFAULT_PORT; }

    private static String randomToken() {
        byte[] bytes = new byte[24];
        new SecureRandom().nextBytes(bytes);
        return Base64.encodeToString(bytes, Base64.NO_WRAP | Base64.URL_SAFE);
    }
}
