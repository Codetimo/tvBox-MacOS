package com.tvbox.bridge;

import android.content.Context;

import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Reflection adapter for CatVod Spider implementations inside classes.dex. */
final class SpiderEngine {
    private final Object spider;
    private final Class<?> spiderClass;
    private final String className;

    private SpiderEngine(Object spider, Class<?> spiderClass, String className) {
        this.spider = spider;
        this.spiderClass = spiderClass;
        this.className = className;
    }

    String className() { return className; }

    /** Report support for the verified PanConfig protocol, rather than claiming every source accepts it. */
    boolean supportsPanConfiguration() {
        try { spiderClass.getClassLoader().loadClass("com.github.catvod.spider.PanConfigGuard"); return true; }
        catch (ClassNotFoundException ignored) { return false; }
    }

    /** Expose the source's configuration catalogue without treating it as a movie search. */
    synchronized String home() throws Exception {
        return requireText(invoke("homeContent", false), "homeContent");
    }

    /** Forward configuration actions using the source's own supported protocol. */
    synchronized String action(String action) throws Exception {
        return requireText(invoke("action", action), "action");
    }

    /** Forward a configuration category request, which is also used by PanConfigGuard for QR login. */
    synchronized String category(String tid, String page, boolean filter, Map<String, String> extend) throws Exception {
        return requireText(invoke("categoryContent", tid, page, filter, new HashMap<>(extend)), "categoryContent");
    }

    static SpiderEngine load(Context context, SpiderPackage pack, String requestedClass, String extend) throws Exception {
        com.github.catvod.crawler.SpiderDebug.init(context.getApplicationContext());
        ClassLoader loader = pack.initializedLoader(context);
        Class<?> type = null;
        Exception last = null;
        for (String candidate : candidates(requestedClass)) {
            try {
                type = loader.loadClass(candidate);
                break;
            } catch (Exception error) {
                last = error;
            }
        }
        if (type == null) throw new ClassNotFoundException("Spider class not found: " + requestedClass, last);
        Constructor<?> constructor = type.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object instance;
        try {
            instance = constructor.newInstance();
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IllegalStateException(cause.toString(), cause);
        }
        SpiderEngine engine = new SpiderEngine(instance, type, type.getName());
        engine.invokeInit(context, extend == null ? "" : extend);
        return engine;
    }

    synchronized String search(String keyword, boolean quick) throws Exception {
        Object value = invoke("searchContent", keyword, quick);
        return requireText(value, "searchContent");
    }

    synchronized String detail(List<String> ids) throws Exception {
        Object value = invoke("detailContent", ids == null ? Collections.<String>emptyList() : ids);
        return requireText(value, "detailContent");
    }

    synchronized String player(String flag, String id, List<String> vipFlags) throws Exception {
        Object value = invoke("playerContent", flag == null ? "" : flag, id == null ? "" : id,
                vipFlags == null ? Collections.<String>emptyList() : vipFlags);
        return requireText(value, "playerContent");
    }

    private void invokeInit(Context context, String extend) throws Exception {
        Method method = findMethod("init", Context.class, String.class);
        if (method == null) return;
        invokeMethod(method, context, extend);
    }

    private Object invoke(String name, Object... args) throws Exception {
        Method method = findCompatibleMethod(name, args);
        if (method == null) throw new NoSuchMethodException(spiderClass.getName() + "." + name);
        return invokeMethod(method, args);
    }

    private Object invokeMethod(Method method, Object... args) throws Exception {
        try {
            method.setAccessible(true);
            return method.invoke(spider, args);
        } catch (InvocationTargetException error) {
            Throwable cause = error.getCause() == null ? error : error.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            throw new IllegalStateException(cause.toString(), cause);
        }
    }

    private Method findMethod(String name, Class<?>... types) {
        try { return spiderClass.getMethod(name, types); }
        catch (NoSuchMethodException ignored) { return null; }
    }

    private Method findCompatibleMethod(String name, Object[] args) {
        for (Method method : spiderClass.getMethods()) {
            if (!method.getName().equals(name) || method.getParameterTypes().length != args.length) continue;
            Class<?>[] types = method.getParameterTypes();
            boolean compatible = true;
            for (int i = 0; i < args.length; i++) {
                if (args[i] == null) continue;
                if (!box(types[i]).isAssignableFrom(args[i].getClass())) { compatible = false; break; }
            }
            if (compatible) return method;
        }
        return null;
    }

    private static Class<?> box(Class<?> type) {
        if (!type.isPrimitive()) return type;
        if (type == boolean.class) return Boolean.class;
        if (type == int.class) return Integer.class;
        if (type == long.class) return Long.class;
        return type;
    }

    private static String requireText(Object value, String method) throws Exception {
        if (!(value instanceof String) || ((String) value).trim().isEmpty()) {
            throw new IllegalStateException(method + " returned an empty response");
        }
        return (String) value;
    }

    private static List<String> candidates(String requested) {
        if (requested == null || requested.trim().isEmpty()) return Collections.emptyList();
        String value = requested.trim();
        ArrayList<String> result = new ArrayList<>();
        result.add(value);
        if (value.startsWith("csp_")) value = value.substring(4);
        if (!value.contains(".")) result.add("com.github.catvod.spider." + value);
        if (!value.endsWith("Guard")) result.add(value + "Guard");
        if (!value.contains(".") && !value.endsWith("Guard")) result.add("com.github.catvod.spider." + value + "Guard");
        return result;
    }

}
