package com.tvbox.bridge;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.nio.file.FileAlreadyExistsException;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/** Content-addressed immutable archives/native libraries, independent of the Android loader. */
final class PackageCache {
    static final long MAX_BYTES = 64L * 1024L * 1024L;
    static final int MAX_VERSIONS = 16;
    static final long MAX_CACHE_BYTES = 1024L * 1024L * 1024L;
    private static int reservations;

    /** Signals that only a fresh process can safely reclaim loaded DEX/native versions. */
    static final class CapacityException extends IOException {
        CapacityException() { super("Spider cache capacity reached; process restart required"); }
    }

    /** Run only before this process loads any Spider; never delete files belonging to a live native loader. */
    static synchronized void cleanupColdCache(File root) throws IOException {
        pruneColdCache(root, 8, MAX_CACHE_BYTES / 2);
    }

    /** Keep recently used versions within both limits, removing dangling references and abandoned staging files. */
    static synchronized void pruneColdCache(File root, int keepVersions, long byteLimit) throws IOException {
        File[] entries = root.listFiles();
        if (entries == null) return;
        java.util.List<File> versions = new java.util.ArrayList<>();
        java.util.List<File> references = new java.util.ArrayList<>();
        for (File entry : entries) {
            if (entry.getName().matches("[0-9a-f]{64}") && entry.isDirectory()) {
                if (new File(entry, "spider.dex.zip").isFile()) versions.add(entry);
                else deleteTree(entry); // URL-keyed native cache or incomplete publication from an older process.
            }
            else if (entry.getName().matches("[0-9a-f]{64}\\.ref")) references.add(entry);
            else if (entry.getName().endsWith(".part") || entry.getName().matches("[0-9a-f]{64}\\.dex\\.zip")
                    || entry.getName().equals("optimized")) deleteTree(entry);
        }
        versions.sort((left, right) -> Long.compare(right.lastModified(), left.lastModified()));
        long retainedBytes = 0; int retainedCount = 0;
        for (File version : versions) {
            long bytes = treeBytes(version);
            if (retainedCount >= keepVersions || retainedBytes + bytes > byteLimit) deleteTree(version);
            else { retainedCount++; retainedBytes += bytes; }
        }
        references.sort((left, right) -> Long.compare(right.lastModified(), left.lastModified()));
        int retainedReferences = 0;
        for (File reference : references) {
            String hash = reference.length() == 64 ? new String(Files.readAllBytes(reference.toPath()), StandardCharsets.US_ASCII) : "";
            if (!hash.matches("[0-9a-f]{64}") || !new File(root, hash + "/spider.dex.zip").isFile()
                    || retainedReferences >= 256) deleteTree(reference);
            else retainedReferences++;
        }
    }

    /** Reserve archive/native expansion room before download; in-process eviction would invalidate live native paths. */
    static synchronized void reserve(File root) throws IOException {
        long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(5);
        while (true) {
            File[] versions = root.listFiles(file -> file.isDirectory() && file.getName().matches("[0-9a-f]{64}"));
            int count = versions == null ? 0 : versions.length;
            long bytes = treeBytes(root);
            // In-flight staging/publication can temporarily account for these bytes or directories.
            if (reservations == 0 && (count >= MAX_VERSIONS || bytes + 4 * MAX_BYTES > MAX_CACHE_BYTES)) {
                throw new CapacityException();
            }
            if (count + reservations < MAX_VERSIONS && bytes + (reservations + 1L) * 4 * MAX_BYTES <= MAX_CACHE_BYTES) {
                reservations++;
                return;
            }
            long remaining = deadline - System.nanoTime();
            if (remaining <= 0) throw new IOException("Spider download capacity temporarily busy");
            try { java.util.concurrent.TimeUnit.NANOSECONDS.timedWait(PackageCache.class, remaining); }
            catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IOException("Spider cache reservation interrupted", interrupted);
            }
        }
    }

    /** Release a download reservation and wake bounded waiters, including on publication failure. */
    static synchronized void releaseReservation() {
        reservations--;
        PackageCache.class.notifyAll();
    }

    /** Count cache bytes without following symbolic links outside the cache. */
    private static long treeBytes(File file) throws IOException {
        if (Files.isSymbolicLink(file.toPath())) return 0;
        if (!file.isDirectory()) return file.length();
        File[] children = file.listFiles();
        if (children == null) throw new IOException("cannot inspect Spider cache");
        long total = 0;
        for (File child : children) total += treeBytes(child);
        return total;
    }

    /** Delete only cold cache entries, never traversing symbolic links. */
    private static void deleteTree(File file) throws IOException {
        if (!Files.isSymbolicLink(file.toPath()) && file.isDirectory()) {
            File[] children = file.listFiles();
            if (children == null) throw new IOException("cannot inspect Spider cache");
            for (File child : children) deleteTree(child);
        }
        Files.deleteIfExists(file.toPath());
    }
    static final class Prepared {
        final File archive, nativeDirectory;
        Prepared(File archive, File nativeDirectory) { this.archive = archive; this.nativeDirectory = nativeDirectory; }
    }

    /** MD5-pinned URLs reuse verified content; unpinned URLs download on every explicit revalidation. */
    static Prepared prepare(File root, String url, String expectedMd5, String abi) throws Exception {
        if (url == null || url.trim().isEmpty()) throw new IOException("spider_url is required");
        URI uri = URI.create(url.trim());
        if (!("https".equalsIgnoreCase(uri.getScheme()) || "http".equalsIgnoreCase(uri.getScheme()))) {
            throw new IOException("spider_url must use http or https");
        }
        if (!root.isDirectory() && !root.mkdirs() && !root.isDirectory()) throw new IOException("cannot create spider cache");
        String md5 = normalizeMd5(expectedMd5);
        if (expectedMd5 != null && !expectedMd5.trim().isEmpty() && md5 == null) throw new IOException("invalid Spider MD5");
        String indexKey = hex(MessageDigest.getInstance("SHA-256").digest((url.trim() + "\n" + md5).getBytes(StandardCharsets.UTF_8)));
        File index = new File(root, indexKey + ".ref");
        File archive = null;
        if (md5 != null && index.isFile() && index.length() == 64) {
            String version = new String(Files.readAllBytes(index.toPath()), StandardCharsets.US_ASCII);
            if (version.matches("[0-9a-f]{64}")) {
                File cached = new File(root, version + "/spider.dex.zip");
                if (cached.isFile() && md5.equals(digest(cached, "MD5")) && version.equals(digest(cached, "SHA-256"))) archive = cached;
            }
        }
        boolean reserved = false;
        try {
            if (archive == null) {
                reserve(root);
                reserved = true;
                File temporary = File.createTempFile("download-", ".part", root);
                try {
                    download(uri, temporary);
                    if (md5 != null && !md5.equals(digest(temporary, "MD5"))) throw new IOException("Spider package MD5 mismatch");
                    try (ZipFile zip = new ZipFile(temporary)) {
                        if (zip.getEntry("classes.dex") == null) throw new IOException("Spider package has no classes.dex");
                    }
                    String version = digest(temporary, "SHA-256");
                    File directory = new File(root, version);
                    if (!directory.isDirectory() && !directory.mkdirs() && !directory.isDirectory()) throw new IOException("cannot create version cache");
                    archive = new File(directory, "spider.dex.zip");
                    if (!archive.exists()) {
                        try { Files.move(temporary.toPath(), archive.toPath()); }
                        catch (FileAlreadyExistsException raced) { /* Another URL published the same content hash. */ }
                    }
                    if (!version.equals(digest(archive, "SHA-256"))) throw new IOException("immutable Spider cache corrupt");
                    archive.setReadable(true, false);
                    archive.setWritable(false, false);
                    File newIndex = File.createTempFile("reference-", ".part", root);
                    try {
                        Files.write(newIndex.toPath(), version.getBytes(StandardCharsets.US_ASCII));
                        Files.move(newIndex.toPath(), index.toPath(), StandardCopyOption.REPLACE_EXISTING);
                    } finally { newIndex.delete(); }
                } finally { temporary.delete(); }
            }
            File nativeDirectory = new File(archive.getParentFile(), "native-" + abi);
            extractNativeLibraries(archive, nativeDirectory, abi);
            archive.getParentFile().setLastModified(System.currentTimeMillis());
            return new Prepared(archive, nativeDirectory);
        } finally { if (reserved) releaseReservation(); }
    }

    /** Bound wall time, response size and interrupted downloads; always disconnect and delete staging files. */
    private static void download(URI uri, File destination) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) uri.toURL().openConnection();
        connection.setConnectTimeout(10_000);
        connection.setReadTimeout(10_000);
        connection.setInstanceFollowRedirects(true);
        connection.setRequestProperty("User-Agent", "TVBoxMacOS-AndroidBridge/1.0");
        long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(18);
        try {
            int status = connection.getResponseCode();
            if (status < 200 || status >= 300) throw new IOException("Spider download HTTP " + status);
            if (connection.getContentLengthLong() > MAX_BYTES) throw new IOException("Spider package exceeds 64 MiB");
            try (InputStream input = new BufferedInputStream(connection.getInputStream());
                 OutputStream output = new FileOutputStream(destination)) {
                byte[] buffer = new byte[32 * 1024]; long total = 0; int count;
                while ((count = input.read(buffer)) != -1) {
                    if (Thread.currentThread().isInterrupted() || System.nanoTime() > deadline) throw new IOException("Spider download interrupted or timed out");
                    total += count;
                    if (total > MAX_BYTES) throw new IOException("Spider package exceeds 64 MiB");
                    output.write(buffer, 0, count);
                }
            }
        } finally { connection.disconnect(); }
    }

    /** A new package hash gets a new native path, even when the replacement library has the same size. */
    private static void extractNativeLibraries(File archive, File target, String abi) throws Exception {
        if (!target.isDirectory() && !target.mkdirs() && !target.isDirectory()) throw new IOException("cannot create native cache");
        try (ZipFile zip = new ZipFile(archive)) {
            java.util.Enumeration<? extends ZipEntry> entries = zip.entries();
            long total = 0;
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                if (entry.isDirectory() || !name.startsWith("assets/") || !name.endsWith(".so")) continue;
                String base = new File(name).getName();
                if (abi.contains("64") ? !base.contains("v8") : !base.contains("v7")) continue;
                File out = new File(target, base);
                // Existing files belong to exactly these archive bytes, never to a URL-based mutable version.
                if (out.isFile()) { verifyNative(out, entry); continue; }
                File temporary = File.createTempFile("native-", ".part", target);
                try {
                    try (InputStream input = zip.getInputStream(entry); OutputStream output = new FileOutputStream(temporary)) {
                        byte[] buffer = new byte[16 * 1024]; int count;
                        while ((count = input.read(buffer)) != -1) {
                            total += count;
                            if (total > 2 * MAX_BYTES) throw new IOException("native library expansion exceeds limit");
                            if (Thread.currentThread().isInterrupted()) throw new IOException("native extraction interrupted");
                            output.write(buffer, 0, count);
                        }
                    }
                    try { Files.move(temporary.toPath(), out.toPath()); }
                    catch (FileAlreadyExistsException raced) { /* Identical archive bytes may be prepared concurrently. */ }
                    verifyNative(out, entry);
                    out.setReadable(true, true);
                    out.setExecutable(true, true);
                    out.setWritable(false, false);
                } finally { temporary.delete(); }
            }
        }
    }

    /** Verify a concurrently published library without replacing a file that may already be loaded. */
    private static void verifyNative(File file, ZipEntry entry) throws IOException {
        java.util.zip.CRC32 crc = new java.util.zip.CRC32();
        try (InputStream input = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buffer = new byte[16 * 1024]; int count;
            while ((count = input.read(buffer)) != -1) crc.update(buffer, 0, count);
        }
        if (file.length() != entry.getSize() || crc.getValue() != entry.getCrc()) {
            throw new IOException("immutable native cache corrupt");
        }
    }

    /** Validate an optional pin before selecting cache policy. */
    static String normalizeMd5(String value) {
        if (value == null) return null;
        String normalized = value.trim().toLowerCase(Locale.US);
        return normalized.matches("[0-9a-f]{32}") ? normalized : null;
    }

    /** Stream file hashes to avoid loading packages into memory. */
    static String digest(File file, String algorithm) throws Exception {
        MessageDigest digest = MessageDigest.getInstance(algorithm);
        try (InputStream input = new BufferedInputStream(new FileInputStream(file))) {
            byte[] buffer = new byte[32 * 1024]; int count;
            while ((count = input.read(buffer)) != -1) digest.update(buffer, 0, count);
        }
        return hex(digest.digest());
    }

    private static String hex(byte[] bytes) {
        StringBuilder value = new StringBuilder();
        for (byte item : bytes) value.append(String.format(Locale.US, "%02x", item & 0xff));
        return value.toString();
    }
}
