package com.tvbox.bridge;

import com.sun.net.httpserver.HttpServer;
import java.io.*;
import java.net.InetSocketAddress;
import java.nio.file.Files;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.zip.*;

/** Standalone regression tests: no emulator, third-party test libraries or installed application required. */
public final class BridgeRegressionTests {
    public static void main(String[] args) throws Exception {
        testTimedOutNativeWorkRetainsAdmission();
        testQueuedDeadlineDoesNotExecute();
        testImmutableCacheAndUnpinnedUpdates();
        testPackageQueuesLeaveCapacityAndRequireRecovery();
        testColdCachePruningAndRuntimeLimits();
        testConcurrentCacheReservationWaitsWithoutRecovery();
        System.out.println("PASS: 6 Bridge regression scenarios (deadlines, fair package queues, circuit breaking, stuck-worker recovery, cold pruning, runtime capacity, immutable updates, checksum)");
    }

    /** Simulate native code that ignores interrupts: other packages run, repeated requests stay bounded. */
    private static void testTimedOutNativeWorkRetainsAdmission() throws Exception {
        RequestExecutor executor = new RequestExecutor(2, 2, 1);
        CountDownLatch entered = new CountDownLatch(1), timedOut = new CountDownLatch(1), other = new CountDownLatch(1);
        AtomicBoolean finish = new AtomicBoolean();
        try {
            check(executor.submit("stuck", 100, () -> {
                entered.countDown();
                while (!finish.get()) {
                    try { Thread.sleep(5); } catch (InterruptedException ignored) { /* Native simulation. */ }
                }
            }, timedOut::countDown), "first request admitted");
            check(entered.await(2, TimeUnit.SECONDS), "operation entered");
            check(timedOut.await(2, TimeUnit.SECONDS), "deadline fired without waiting for native exit");
            check(!executor.submit("stuck", 100, () -> {}, () -> {}), "timeout must retain package admission");
            check(executor.submit("healthy", 1000, other::countDown, () -> {}), "other package admitted");
            check(other.await(2, TimeUnit.SECONDS), "other package unaffected");
        } finally { finish.set(true); executor.stop(); }
    }

    /** Expired queued work must never run later; full admission returns immediately instead of accumulating tasks. */
    private static void testQueuedDeadlineDoesNotExecute() throws Exception {
        RequestExecutor executor = new RequestExecutor(1, 1, 1);
        CountDownLatch entered = new CountDownLatch(1), release = new CountDownLatch(1), expired = new CountDownLatch(1);
        AtomicBoolean ran = new AtomicBoolean();
        try {
            check(executor.submit("first", 3000, () -> {
                entered.countDown();
                try { release.await(); } catch (InterruptedException ignored) {}
            }, () -> {}), "first admitted");
            check(entered.await(2, TimeUnit.SECONDS), "worker occupied");
            check(executor.submit("queued", 100, () -> ran.set(true), expired::countDown), "queued admitted");
            check(!executor.submit("overflow", 100, () -> {}, () -> {}), "bounded queue rejects overflow");
            check(expired.await(2, TimeUnit.SECONDS), "queued timeout returned");
            release.countDown();
            CountDownLatch drained = new CountDownLatch(1);
            long admissionDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
            boolean admitted = false;
            while (!(admitted = executor.submit("after", 1000, drained::countDown, () -> {}))
                    && System.nanoTime() < admissionDeadline) Thread.sleep(5);
            check(admitted, "expired queue slot reclaimed after timeout delivery");
            check(drained.await(2, TimeUnit.SECONDS), "queue drained");
            check(!ran.get(), "expired operation never executed");
        } finally { release.countDown(); executor.stop(); }
    }

    /** Same URL and same library byte count must still yield a new immutable version; pinned content stays cached. */
    private static void testImmutableCacheAndUnpinnedUpdates() throws Exception {
        File root = Files.createTempDirectory("tvbox-cache-test-").toFile();
        AtomicReference<byte[]> bytes = new AtomicReference<>(archive("AAAA"));
        AtomicInteger downloads = new AtomicInteger();
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/spider", exchange -> {
            downloads.incrementAndGet(); byte[] response = bytes.get();
            exchange.sendResponseHeaders(200, response.length);
            try (OutputStream output = exchange.getResponseBody()) { output.write(response); }
        });
        server.start();
        try {
            String url = "http://127.0.0.1:" + server.getAddress().getPort() + "/spider";
            ExecutorService preparers = Executors.newFixedThreadPool(2);
            PackageCache.Prepared first;
            try {
                CountDownLatch begin = new CountDownLatch(1);
                Future<PackageCache.Prepared> left = preparers.submit(() -> {
                    begin.await(); return PackageCache.prepare(root, url + "?source=1", null, "arm64-v8a");
                });
                Future<PackageCache.Prepared> right = preparers.submit(() -> {
                    begin.await(); return PackageCache.prepare(root, url + "?source=2", null, "arm64-v8a");
                });
                begin.countDown();
                first = left.get(5, TimeUnit.SECONDS);
                PackageCache.Prepared concurrent = right.get(5, TimeUnit.SECONDS);
                check(first.archive.equals(concurrent.archive), "different URLs safely publish identical content concurrently");
                check(read(new File(concurrent.nativeDirectory, "libtestv8.so")).equals("AAAA"), "concurrent native extraction valid");
            } finally { preparers.shutdownNow(); }
            bytes.set(archive("BBBB"));
            PackageCache.Prepared second = PackageCache.prepare(root, url, null, "arm64-v8a");
            check(!first.archive.equals(second.archive), "updated bytes use new archive path");
            check(!first.nativeDirectory.equals(second.nativeDirectory), "updated native bytes use new directory");
            check(read(new File(first.nativeDirectory, "libtestv8.so")).equals("AAAA"), "loaded old library preserved");
            check(read(new File(second.nativeDirectory, "libtestv8.so")).equals("BBBB"), "same-size updated library extracted");
            String pin = PackageCache.digest(second.archive, "MD5");
            PackageCache.prepare(root, url, pin, "arm64-v8a");
            int before = downloads.get();
            PackageCache.prepare(root, url, pin, "arm64-v8a");
            check(downloads.get() == before, "verified pinned package reused");
            try {
                PackageCache.prepare(root, url, "00000000000000000000000000000000", "arm64-v8a");
                throw new AssertionError("mismatched checksum accepted");
            } catch (IOException expected) { check(expected.getMessage().contains("MD5 mismatch"), "checksum failure explicit"); }
            try {
                PackageCache.prepare(root, url, "invalid", "arm64-v8a");
                throw new AssertionError("invalid checksum silently ignored");
            } catch (IOException expected) { check(expected.getMessage().contains("invalid Spider MD5"), "invalid pin rejected"); }
            File[] partials = root.listFiles((directory, name) -> name.endsWith(".part"));
            check(partials != null && partials.length == 0, "failed downloads leave no staging files");
        } finally { server.stop(0); delete(root); }
    }

    /** Two fully admitted stuck packages must leave workers for healthy work; queued work never runs after expiry. */
    private static void testPackageQueuesLeaveCapacityAndRequireRecovery() throws Exception {
        RequestExecutor executor = new RequestExecutor(16, 24, 8, 50);
        AtomicBoolean finish = new AtomicBoolean();
        AtomicInteger executed = new AtomicInteger();
        CountDownLatch entered = new CountDownLatch(4), expired = new CountDownLatch(16), healthy = new CountDownLatch(1);
        Runnable stuck = () -> {
            executed.incrementAndGet(); entered.countDown();
            while (!finish.get()) {
                try { Thread.sleep(5); } catch (InterruptedException ignored) { /* Simulate JNI. */ }
            }
        };
        try {
            for (int index = 0; index < 8; index++) {
                check(executor.submit("stuck-a", 400, stuck, expired::countDown), "package A admits its bounded queue");
                check(executor.submit("stuck-b", 400, stuck, expired::countDown), "package B admits its bounded queue");
            }
            check(entered.await(2, TimeUnit.SECONDS), "two execution slots per package occupied");
            check(executor.submit("healthy", 200, healthy::countDown, () -> {}), "healthy package admitted with two stuck packages");
            check(healthy.await(2, TimeUnit.SECONDS), "healthy package actually executes before stuck deadlines");
            check(expired.await(2, TimeUnit.SECONDS), "running and queued callers all receive deadlines");
            check(executed.get() == 4, "same-package waiters never occupy business threads");
            check(!executor.submit("stuck-a", 200, () -> {}, () -> {}), "timeout opens package circuit");
            long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
            while (!executor.requiresRecovery() && System.nanoTime() < until) Thread.sleep(5);
            check(executor.requiresRecovery(), "health requires process recovery when interrupted work stays alive");
            check(!executor.submit("healthy", 200, () -> {}, () -> {}), "recovery state stops admission instead of accumulating work");
        } finally { finish.set(true); executor.stop(); }
    }

    /** Cold pruning observes count/byte limits; a live session rejects new versions without deleting existing files. */
    private static void testColdCachePruningAndRuntimeLimits() throws Exception {
        File root = Files.createTempDirectory("tvbox-cache-limits-").toFile();
        try {
            for (int index = 1; index <= 4; index++) {
                String hash = String.format("%064x", index);
                File version = new File(root, hash); check(version.mkdir(), "fixture version created");
                Files.write(new File(version, "spider.dex.zip").toPath(), new byte[10]);
                Files.write(new File(root, hash + ".ref").toPath(), hash.getBytes("US-ASCII"));
                check(version.setLastModified(index * 1000L), "fixture access ordering set");
            }
            Files.write(new File(root, "download-abandoned.part").toPath(), new byte[1]);
            File legacyArchive = new File(root, String.format("%064x", 99) + ".dex.zip");
            Files.write(legacyArchive.toPath(), new byte[1]);
            File legacyOptimized = new File(root, "optimized"); check(legacyOptimized.mkdir(), "legacy optimized fixture");
            Files.write(new File(legacyOptimized, "old.odex").toPath(), new byte[1]);
            PackageCache.pruneColdCache(root, 3, 20);
            check(root.listFiles(File::isDirectory).length == 2, "cold cache honors byte budget as well as count");
            check(new File(root, String.format("%064x", 4)).isDirectory(), "most recent version retained");
            check(!new File(root, String.format("%064x", 1) + ".ref").exists(), "dangling reference removed");
            check(!new File(root, "download-abandoned.part").exists(), "abandoned staging removed only on cold start");
            check(!legacyArchive.exists() && !legacyOptimized.exists(), "known obsolete archive and optimized caches reclaimed");
            PackageCache.pruneColdCache(root, 1, 100);
            check(root.listFiles(File::isDirectory).length == 1, "cold version count bound enforced");
            for (int index = 5; index < 20; index++) check(new File(root, String.format("%064x", index)).mkdir(), "runtime version fixture");
            try {
                PackageCache.prepare(root, "http://127.0.0.1:1/spider", null, "arm64-v8a");
                throw new AssertionError("runtime version limit ignored");
            } catch (PackageCache.CapacityException expected) { /* Must reject before network access. */ }
            check(root.listFiles(File::isDirectory).length == 16, "runtime limit never deletes potentially loaded versions");
            PackageCache.pruneColdCache(root, 0, 0);
            File large = new File(root, "retained-cache");
            try (RandomAccessFile file = new RandomAccessFile(large, "rw")) { file.setLength(PackageCache.MAX_CACHE_BYTES); }
            try {
                PackageCache.prepare(root, "http://127.0.0.1:1/spider", null, "arm64-v8a");
                throw new AssertionError("runtime byte limit ignored");
            } catch (PackageCache.CapacityException expected) { /* Sparse fixture bounds disk use. */ }
            check(large.length() == PackageCache.MAX_CACHE_BYTES, "live byte limit preserves existing files");
        } finally { delete(root); }
    }

    /** Temporary reservations wait for released room rather than misclassifying concurrency as permanent cache exhaustion. */
    private static void testConcurrentCacheReservationWaitsWithoutRecovery() throws Exception {
        File root = Files.createTempDirectory("tvbox-cache-reservations-").toFile();
        ExecutorService waiter = Executors.newSingleThreadExecutor();
        int held = 0;
        try {
            Files.write(new File(root, "existing-data").toPath(), new byte[1]);
            for (int index = 0; index < 3; index++) { PackageCache.reserve(root); held++; }
            CountDownLatch entered = new CountDownLatch(1);
            Future<?> fourth = waiter.submit(() -> {
                entered.countDown();
                try { PackageCache.reserve(root); }
                catch (IOException failure) { throw new RuntimeException(failure); }
                PackageCache.releaseReservation();
            });
            check(entered.await(2, TimeUnit.SECONDS), "fourth downloader requests a reservation");
            Thread.sleep(100);
            check(!fourth.isDone(), "temporary reservation pressure waits instead of requiring process recovery");
            PackageCache.releaseReservation(); held--;
            fourth.get(2, TimeUnit.SECONDS);
        } finally {
            while (held-- > 0) PackageCache.releaseReservation();
            waiter.shutdownNow(); delete(root);
        }
    }

    private static byte[] archive(String nativeBytes) throws Exception {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(bytes)) {
            zip.putNextEntry(new ZipEntry("classes.dex")); zip.write("fixture".getBytes("UTF-8")); zip.closeEntry();
            zip.putNextEntry(new ZipEntry("assets/libtestv8.so")); zip.write(nativeBytes.getBytes("UTF-8")); zip.closeEntry();
        }
        return bytes.toByteArray();
    }
    private static String read(File file) throws Exception { return new String(Files.readAllBytes(file.toPath()), "UTF-8"); }
    private static void check(boolean condition, String message) { if (!condition) throw new AssertionError(message); }
    private static void delete(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) delete(child);
        file.setWritable(true); file.delete();
    }
}
