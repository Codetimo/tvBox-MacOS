package com.tvbox.bridge;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

/** Bounded fair admission: waiting for a package never occupies a business worker. */
final class RequestExecutor {
    private final ThreadPoolExecutor workers;
    private final ScheduledThreadPoolExecutor deadlines = new ScheduledThreadPoolExecutor(1);
    private final Map<String, Integer> admitted = new HashMap<>(), runningByPackage = new HashMap<>();
    private final Map<String, Long> circuitUntil = new HashMap<>();
    private final List<Work> pending = new ArrayList<>();
    private final int threads, queueSize, perPackage, parallelPerPackage;
    private final long recoveryGraceMillis;
    private int running;
    private boolean stopped, recoveryRequired;

    RequestExecutor(int threads, int queueSize, int perPackage) {
        this(threads, queueSize, perPackage, 5_000);
    }

    /** Allow short deterministic recovery checks in standalone regression tests. */
    RequestExecutor(int threads, int queueSize, int perPackage, long recoveryGraceMillis) {
        this.threads = threads;
        this.queueSize = queueSize;
        this.perPackage = perPackage;
        this.parallelPerPackage = Math.min(2, perPackage);
        this.recoveryGraceMillis = recoveryGraceMillis;
        deadlines.setRemoveOnCancelPolicy(true);
        workers = new ThreadPoolExecutor(threads, threads, 0, TimeUnit.MILLISECONDS, new ArrayBlockingQueue<>(threads));
    }

    /** Accept bounded package queues; deadlines include time spent waiting for an execution slot. */
    synchronized boolean submit(String key, long timeoutMillis, Runnable operation, Runnable timeout) {
        long now = System.nanoTime();
        circuitUntil.entrySet().removeIf(entry -> entry.getValue() <= now && !admitted.containsKey(entry.getKey()));
        if (stopped || recoveryRequired || circuitUntil.containsKey(key) || circuitUntil.size() >= 256
                || admitted.getOrDefault(key, 0) >= perPackage) return false;
        boolean canRun = running < threads && runningByPackage.getOrDefault(key, 0) < parallelPerPackage;
        if (!canRun && pending.size() >= queueSize) return false;
        Work work = new Work(key, operation, timeout);
        admitted.put(key, admitted.getOrDefault(key, 0) + 1);
        work.deadline = deadlines.schedule(() -> expire(work), timeoutMillis, TimeUnit.MILLISECONDS);
        pending.add(work);
        dispatch();
        return true;
    }

    /** Only runnable packages enter the worker pool, leaving capacity for unrelated packages. Caller holds this lock. */
    private void dispatch() {
        for (Iterator<Work> iterator = pending.iterator(); iterator.hasNext() && running < threads;) {
            Work work = iterator.next();
            if (runningByPackage.getOrDefault(work.key, 0) >= parallelPerPackage) continue;
            iterator.remove();
            work.dispatched = true;
            running++;
            runningByPackage.put(work.key, runningByPackage.getOrDefault(work.key, 0) + 1);
            workers.execute(() -> execute(work));
        }
    }

    /** Retain the occupied slot until third-party code actually exits, even if interruption is ignored. */
    private void execute(Work work) {
        try {
            synchronized (this) {
                if (work.terminal) return;
                work.thread = Thread.currentThread();
            }
            work.operation.run();
        } finally {
            synchronized (this) {
                work.thread = null;
                work.exited = true;
                work.terminal = true;
                work.deadline.cancel(false);
                running--;
                decrement(runningByPackage, work.key);
                decrement(admitted, work.key);
                if (!stopped) dispatch();
            }
        }
    }

    /** Open a package circuit and cancel its queued work without executing third-party code. */
    private void expire(Work work) {
        List<Work> expired = new ArrayList<>();
        synchronized (this) {
            if (work.terminal || stopped) return;
            circuitUntil.put(work.key, System.nanoTime() + TimeUnit.SECONDS.toNanos(30));
            markExpired(work, expired);
            for (Iterator<Work> iterator = pending.iterator(); iterator.hasNext();) {
                Work queued = iterator.next();
                if (!queued.key.equals(work.key)) continue;
                iterator.remove();
                markExpired(queued, expired);
            }
            pending.remove(work);
            if (work.dispatched) deadlines.schedule(() -> {
                synchronized (RequestExecutor.this) {
                    // JNI cannot be safely stopped by Java; recovery must replace the Android process.
                    if (!work.exited) recoveryRequired = true;
                }
            }, recoveryGraceMillis, TimeUnit.MILLISECONDS);
            dispatch();
        }
        try { for (Work item : expired) item.timeout.run(); }
        finally {
            // Deliver the timeout before interruption can generate a competing provider error response.
            synchronized (this) { if (work.thread != null) work.thread.interrupt(); }
        }
    }

    /** Complete timeout bookkeeping once, retaining admission only for dispatched operations. */
    private void markExpired(Work work, List<Work> expired) {
        if (work.terminal) return;
        work.terminal = true;
        work.deadline.cancel(false);
        if (!work.dispatched) decrement(admitted, work.key);
        expired.add(work);
    }

    /** Remove idle package keys so browsing many sources does not grow maps indefinitely. */
    private static void decrement(Map<String, Integer> counts, String key) {
        int remaining = counts.getOrDefault(key, 1) - 1;
        if (remaining <= 0) counts.remove(key); else counts.put(key, remaining);
    }

    /** A listener can be alive while business execution requires process recovery. */
    synchronized boolean requiresRecovery() { return recoveryRequired; }

    /** Expose occupied slots without URLs, credentials or package identities. */
    synchronized int activeCount() { return running; }

    /** Stop admission and interrupt cooperative requests; the host force-stops unrecoverable JNI processes. */
    synchronized void stop() {
        stopped = true;
        pending.clear();
        workers.shutdownNow();
        deadlines.shutdownNow();
    }

    private static final class Work {
        final String key;
        final Runnable operation, timeout;
        ScheduledFuture<?> deadline;
        Thread thread;
        boolean dispatched, terminal, exited;
        Work(String key, Runnable operation, Runnable timeout) {
            this.key = key; this.operation = operation; this.timeout = timeout;
        }
    }
}
