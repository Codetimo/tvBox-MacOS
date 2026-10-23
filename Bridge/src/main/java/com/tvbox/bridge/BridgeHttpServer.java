package com.tvbox.bridge;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.HashMap;

/** Minimal dependency-free HTTP/1.1 loopback server used by the macOS client. */
final class BridgeHttpServer {
    interface StatusProvider { JSONObject status(); }
    interface EngineProvider { SpiderEngine engine(JSONObject request) throws Exception; }
    interface PanLoginProvider { JSONObject login(JSONObject request) throws Exception; }

    private static final int MAX_BODY = 2 * 1024 * 1024;
    private final int port;
    private final String token;
    private final StatusProvider statusProvider;
    private final EngineProvider engineProvider;
    private final PanLoginProvider panLoginProvider;
    // HTTP readers never wait for Spider execution, so health remains independent of slow sites.
    private final ExecutorService workers = new ThreadPoolExecutor(4, 4, 0, TimeUnit.MILLISECONDS,
            new ArrayBlockingQueue<>(32));
    private final RequestExecutor operations = new RequestExecutor(16, 24, 8);
    private static final AtomicLong REQUEST_IDS = new AtomicLong();
    private final java.util.Set<Socket> clients = java.util.concurrent.ConcurrentHashMap.newKeySet();
    private volatile ServerSocket socket;
    private volatile boolean running;

    BridgeHttpServer(int port, String token, StatusProvider statusProvider, EngineProvider engineProvider, PanLoginProvider panLoginProvider) {
        if (port < 1 || port > 65535) throw new IllegalArgumentException("invalid port");
        this.port = port;
        this.token = token;
        this.statusProvider = statusProvider;
        this.engineProvider = engineProvider;
        this.panLoginProvider = panLoginProvider;
    }

    void start() throws IOException {
        if (running) return;
        ServerSocket server = new ServerSocket(port, 16, InetAddress.getByName("127.0.0.1"));
        server.setReuseAddress(true);
        socket = server;
        running = true;
        Thread acceptor = new Thread(() -> acceptLoop(server), "tvbox-spider-http");
        acceptor.setDaemon(true);
        acceptor.start();
    }

    void stop() {
        running = false;
        ServerSocket server = socket;
        socket = null;
        if (server != null) try { server.close(); } catch (IOException ignored) {}
        workers.shutdownNow();
        operations.stop();
        for (Socket client : clients) try { client.close(); } catch (IOException ignored) {}
        clients.clear();
    }

    /** Include business-worker liveness, since a responsive HTTP listener alone is not readiness. */
    private JSONObject healthStatus() {
        JSONObject result = statusProvider.status();
        try {
            boolean recovery = operations.requiresRecovery() || result.optBoolean("restartRequired", false);
            result.put("restartRequired", recovery);
            result.put("activeOperations", operations.activeCount());
            if (recovery) {
                result.put("ok", false);
                result.put("ready", false);
                result.put("state", "recovery-required");
            }
        } catch (JSONException ignored) {}
        return result;
    }

    private void acceptLoop(ServerSocket server) {
        while (running) {
            try {
                Socket client = server.accept();
                clients.add(client);
                client.setSoTimeout(5_000);
                try { workers.execute(() -> handle(client)); }
                catch (RejectedExecutionException busy) { clients.remove(client); client.close(); }
            } catch (IOException error) {
                if (running) android.util.Log.w("TVBoxBridge", "accept failed", error);
            }
        }
    }

    /** Parse and authenticate on the ingress pool, then transfer socket ownership to a bounded operation. */
    private void handle(Socket client) {
        String requestId = Long.toHexString(REQUEST_IDS.incrementAndGet());
        long started = System.nanoTime();
        AtomicBoolean completed = new AtomicBoolean();
        try {
            Request request = Request.parse(new BufferedInputStream(client.getInputStream()));
            if (!authorized(request)) {
                complete(client, completed, new Response(401, error("unauthorized")), requestId, "none", "auth", started);
                return;
            }
            if ("GET".equals(request.method) && "/health".equals(request.path)) {
                complete(client, completed, new Response(200, healthStatus()), requestId, "none", "health", started);
                return;
            }
            JSONObject body = request.json();
            String site = safeSite(value(body, request.query, "spider_class", "spiderClass", "site"));
            String action = request.path.matches("/api/[a-z-]+") ? request.path.substring(5) : "unknown";
            String packageKey = value(body, request.query, "spider_url", "spider");
            boolean accepted = operations.submit(packageKey, 20_000, () -> {
                Response response;
                try { response = route(request); }
                catch (VirtualMachineError | ThreadDeath fatal) {
                    // Avoid allocating an error JSON after VM failure, but always release the client socket.
                    try { client.close(); } catch (IOException ignored) {}
                    finally { clients.remove(client); }
                    throw fatal;
                } catch (Throwable failure) {
                    // FutureTask otherwise swallows provider AssertionError and leaves the socket unanswered.
                    response = new Response(502, error(failure));
                }
                complete(client, completed, response, requestId, site, action, started);
            }, () -> complete(client, completed, new Response(504, error("站源执行超时，请尝试其他站源。")),
                    requestId, site, action, started));
            if (!accepted) complete(client, completed, new Response(503, error("站源繁忙或仍有超时任务未退出，请尝试其他站源。")),
                    requestId, site, action, started);
        } catch (Exception failure) {
            complete(client, completed, new Response(400, error("invalid request")), requestId, "none", "parse", started);
        }
    }

    /** Only one result wins a timeout race; never include request URLs, credentials or exception messages in logs. */
    private void complete(Socket client, AtomicBoolean completed, Response response, String id,
                                 String site, String action, long started) {
        if (!completed.compareAndSet(false, true)) {
            // A deadline may race a response blocked in write; close that socket to enforce the deadline.
            try { client.close(); } catch (IOException ignored) {}
            return;
        }
        long elapsed = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started);
        String category = response.status == 200 ? "ok" : response.status == 504 ? "timeout" :
                response.status == 503 ? "unavailable" : response.status == 502 ? "upstream" : "request";
        if (!"health".equals(action)) android.util.Log.i("TVBoxBridge", "request_id=" + id + " site=" + site +
                " action=" + action + " duration_ms=" + elapsed + " status=" + response.status + " category=" + category + " error_type=" + response.body.optString("error_type", "none"));
        try (Socket ignored = client; OutputStream output = new BufferedOutputStream(client.getOutputStream())) {
            response.body.put("request_id", id);
            write(output, response.status, response.body);
        } catch (Exception ignored) { /* Disconnected clients do not alter operation status. */ }
        finally { clients.remove(client); }
    }

    /** Site class names are safe identifiers; reject arbitrary URL/credential-like values instead of echoing them. */
    private static String safeSite(String value) {
        return value.matches("[A-Za-z0-9_.$-]{1,120}") ? value : "redacted";
    }

    private boolean authorized(Request request) {
        String provided = request.headers.get("x-tvbox-token");
        if (provided == null) {
            String authorization = request.headers.get("authorization");
            if (authorization != null && authorization.regionMatches(true, 0, "Bearer ", 0, 7)) {
                provided = authorization.substring(7).trim();
            }
        }
        if (provided == null) return false;
        return constantTimeEquals(token, provided);
    }

    private Response route(Request request) throws Exception {
        if ("GET".equals(request.method) && "/health".equals(request.path)) {
            return new Response(200, healthStatus());
        }
        if (!("POST".equals(request.method) || "GET".equals(request.method))) return new Response(405, error("method not allowed"));
        JSONObject body = request.json();
        if ("/api/pan-login".equals(request.path)) {
            if (!"POST".equals(request.method)) return new Response(405, error("POST required"));
            // Login has its own package path: do not initialize a site or overwrite its pending credentials.
            if (body.has("pan_cookies")) return new Response(400, error("扫码登录请求不能携带已有 Cookie。"));
            String provider = body.optString("provider", "");
            String action = body.optString("action", "");
            if (!("quark".equals(provider) || "baidu".equals(provider)) ||
                    !("start".equals(action) || "poll".equals(action) || "cancel".equals(action))) {
                return new Response(400, error("无效的扫码登录请求。"));
            }
            if ("start".equals(action) && body.optLong("pan_cookie_version", -1) < 0) {
                return new Response(400, error("扫码登录缺少凭据版本，请更新客户端。"));
            }
            try { return ok(panLoginProvider.login(body).toString()); }
            catch (Exception failure) {
                android.util.Log.w("TVBoxBridge", "QR login failed: " + failure.getClass().getSimpleName());
                return new Response(502, error("获取扫码登录状态失败，请刷新二维码或更新站源。"));
            }
        }
        if ((body.has("pan_cookies") || "/api/pan-cookies".equals(request.path)) && !"POST".equals(request.method)) {
            return new Response(405, error("POST required"));
        }
        // Keep compatibility with the first macOS client, which uses a GET
        // query for Spider URL, checksum, site class, and `wd` keyword.
        copyQuery(body, request.query, "spider", "spider_url", "md5", "spider_md5", "site", "spiderClass", "spider_class", "ext", "spider_ext", "wd", "keyword", "key");
        SpiderEngine engine;
        try { engine = engineProvider.engine(body); }
        catch (Exception error) { return new Response(503, requestError(error, body)); }
        try {
            if ("/api/pan-cookies".equals(request.path)) {
                if (!"POST".equals(request.method)) return new Response(405, error("POST required"));
                return ok("{\"synced\":" + engine.supportsPanConfiguration() + "}");
            }
            if ("/api/home".equals(request.path)) return ok(engine.home());
            if ("/api/action".equals(request.path)) {
                if (!"POST".equals(request.method)) return new Response(405, error("POST required"));
                return ok(engine.action(body.optString("action", "")));
            }
            if ("/api/category".equals(request.path)) {
                String tid = value(body, request.query, "tid", "type_id");
                String page = value(body, request.query, "pg", "page");
                if (page.isEmpty()) page = "1";
                return ok(engine.category(tid, page, bool(body, request.query, "filter", false), stringMap(body.opt("extend"))));
            }
            if ("/api/search".equals(request.path)) {
                String keyword = value(body, request.query, "keyword", "key");
                if (keyword.isEmpty()) return new Response(400, error("keyword is required"));
                String raw = engine.search(keyword, bool(body, request.query, "quick", false));
                return ok(raw);
            }
            if ("/api/detail".equals(request.path)) {
                List<String> ids = list(body, "ids");
                if (ids.isEmpty()) {
                    String id = value(body, request.query, "id");
                    if (!id.isEmpty()) ids = Collections.singletonList(id);
                }
                if (ids.isEmpty()) return new Response(400, error("ids is required"));
                return ok(engine.detail(ids));
            }
            if ("/api/player".equals(request.path)) {
                String flag = value(body, request.query, "flag");
                String id = value(body, request.query, "id");
                if (id.isEmpty()) return new Response(400, error("id is required"));
                return ok(engine.player(flag, id, list(body, "vipFlags")));
            }
            return new Response(404, error("unknown endpoint"));
        } catch (Exception error) {
            // Spider errors are explicit failures; never wrap them as an empty
            // successful result because the caller needs to try another source.
            return new Response(502, requestError(error, body));
        }
    }

    private static Response ok(String raw) {
        JSONObject body = new JSONObject();
        try {
            body.put("ok", true);
            body.put("data", jsonValue(raw));
        } catch (JSONException error) {
            return new Response(502, error(error));
        }
        return new Response(200, body);
    }

    private static Object jsonValue(String raw) throws JSONException {
        String value = raw == null ? "" : raw.trim();
        if (value.startsWith("{") || value.startsWith("[")) return new JSONTokener(value).nextValue();
        return value;
    }

    private static JSONObject error(String message) {
        JSONObject body = new JSONObject();
        try { body.put("ok", false).put("error", message == null ? "unknown error" : message); }
        catch (JSONException ignored) {}
        return body;
    }

    /** Third-party exceptions may echo ext/credentials; never log or return their messages for auth requests. */
    private static JSONObject requestError(Exception failure, JSONObject request) {
        if (!request.has("pan_cookies")) return error(failure);
        return error(failure);
    }

    private static JSONObject error(Throwable failure) {
        Throwable cause = failure;
        for (int i = 0; i < 12 && cause.getCause() != null && cause.getCause() != cause; i++) cause = cause.getCause();
        // Third-party messages and stack traces can contain signed URLs even without pan_cookies.
        JSONObject body = error("站源调用失败（" + cause.getClass().getSimpleName() + "），请尝试其他站源或更新配置。");
        try { body.put("error_type", cause.getClass().getSimpleName()); } catch (JSONException ignored) {}
        return body;
    }

    private static String value(JSONObject body, java.util.Map<String, String> query, String... names) {
        for (String name : names) {
            if (body.has(name) && !body.isNull(name)) return body.optString(name, "").trim();
            String queryValue = query.get(name);
            if (queryValue != null) return queryValue.trim();
        }
        return "";
    }

    private static void copyQuery(JSONObject body, java.util.Map<String, String> query, String... names) throws JSONException {
        for (String name : names) {
            if (!body.has(name) && query.containsKey(name)) body.put(name, query.get(name));
        }
        // `site` is the adapter name in TVBox JSON and is also the class name
        // for csp_* entries. The explicit class field still takes precedence.
        if (!body.has("spider_class") && !body.has("spiderClass") && body.has("site")) {
            body.put("spider_class", body.optString("site", ""));
        }
        if (!body.has("keyword") && body.has("wd")) body.put("keyword", body.optString("wd", ""));
    }

    private static boolean bool(JSONObject body, java.util.Map<String, String> query, String name, boolean fallback) {
        if (body.has(name)) return body.optBoolean(name, fallback);
        String value = query.get(name);
        return value == null ? fallback : "1".equals(value) || "true".equalsIgnoreCase(value);
    }

    private static List<String> list(JSONObject body, String key) {
        JSONArray array = body.optJSONArray(key);
        if (array == null) return Collections.emptyList();
        ArrayList<String> result = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) {
            String value = array.optString(i, "").trim();
            if (!value.isEmpty()) result.add(value);
        }
        return result;
    }

    private static HashMap<String, String> stringMap(Object value) {
        HashMap<String, String> result = new HashMap<>();
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            java.util.Iterator<String> keys = object.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                result.put(key, object.optString(key, ""));
            }
        } else if (value instanceof String && !((String) value).trim().isEmpty()) {
            result.put("ext", (String) value);
        }
        return result;
    }

    private static boolean constantTimeEquals(String expected, String provided) {
        if (expected == null || provided == null) return false;
        return MessageDigest.isEqual(expected.getBytes(StandardCharsets.UTF_8), provided.getBytes(StandardCharsets.UTF_8));
    }

    private static void write(OutputStream output, int status, JSONObject body) throws IOException {
        byte[] bytes = body.toString().getBytes(StandardCharsets.UTF_8);
        String reason = status == 200 ? "OK" : status == 400 ? "Bad Request" : status == 401 ? "Unauthorized" :
                status == 404 ? "Not Found" : status == 405 ? "Method Not Allowed" : status == 502 ? "Bad Gateway" : status == 504 ? "Gateway Timeout" : "Service Unavailable";
        String header = "HTTP/1.1 " + status + " " + reason + "\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Cache-Control: no-store\r\n" +
                "Content-Length: " + bytes.length + "\r\nConnection: close\r\n\r\n";
        output.write(header.getBytes(StandardCharsets.US_ASCII));
        output.write(bytes);
        output.flush();
    }

    private static final class Response {
        final int status; final JSONObject body;
        Response(int status, JSONObject body) { this.status = status; this.body = body; }
    }

    private static final class Request {
        final String method, path;
        final java.util.Map<String, String> query, headers;
        final byte[] body;

        private Request(String method, String path, java.util.Map<String, String> query,
                        java.util.Map<String, String> headers, byte[] body) {
            this.method = method; this.path = path; this.query = query; this.headers = headers; this.body = body;
        }

        static Request parse(InputStream input) throws Exception {
            String requestLine = line(input);
            if (requestLine == null) throw new IOException("empty request");
            String[] pieces = requestLine.split(" ", 3);
            if (pieces.length < 2) throw new IOException("invalid request line");
            String target = pieces[1];
            int question = target.indexOf('?');
            String path = question >= 0 ? target.substring(0, question) : target;
            java.util.Map<String, String> query = parsePairs(question >= 0 ? target.substring(question + 1) : "");
            java.util.Map<String, String> headers = new java.util.HashMap<>();
            String header;
            int headerCount = 0;
            while ((header = line(input)) != null && !header.isEmpty()) {
                if (++headerCount > 64) throw new IOException("too many headers");
                int colon = header.indexOf(':');
                if (colon > 0) headers.put(header.substring(0, colon).trim().toLowerCase(Locale.US), header.substring(colon + 1).trim());
            }
            int length = 0;
            String contentLength = headers.get("content-length");
            try { length = Integer.parseInt(contentLength == null ? "0" : contentLength); }
            catch (NumberFormatException error) { throw new IOException("invalid content length"); }
            if (length < 0 || length > MAX_BODY) throw new IOException("request body too large");
            byte[] body = readExactly(input, length);
            return new Request(pieces[0].toUpperCase(Locale.US), path, query, headers, body);
        }

        JSONObject json() throws JSONException {
            if (body.length == 0) return new JSONObject();
            return new JSONObject(new String(body, StandardCharsets.UTF_8));
        }

        private static String line(InputStream input) throws IOException {
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            int value;
            while ((value = input.read()) != -1) {
                if (value == '\n') break;
                if (value != '\r') output.write(value);
                if (output.size() > 16 * 1024) throw new IOException("header too large");
            }
            if (value == -1 && output.size() == 0) return null;
            return output.toString("UTF-8");
        }

        private static byte[] readExactly(InputStream input, int length) throws IOException {
            byte[] data = new byte[length]; int offset = 0;
            while (offset < length) {
                int count = input.read(data, offset, length - offset);
                if (count == -1) throw new IOException("truncated request body");
                offset += count;
            }
            return data;
        }

        private static java.util.Map<String, String> parsePairs(String value) throws Exception {
            java.util.Map<String, String> result = new java.util.HashMap<>();
            if (value.isEmpty()) return result;
            for (String pair : value.split("&")) {
                if (pair.isEmpty()) continue;
                int equals = pair.indexOf('=');
                String key = equals < 0 ? pair : pair.substring(0, equals);
                String item = equals < 0 ? "" : pair.substring(equals + 1);
                result.put(URLDecoder.decode(key, "UTF-8"), URLDecoder.decode(item, "UTF-8"));
            }
            return result;
        }
    }
}
