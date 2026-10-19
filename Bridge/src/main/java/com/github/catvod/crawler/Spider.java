package com.github.catvod.crawler;

import android.content.Context;
import java.util.HashMap;
import java.util.List;

/**
 * The small ABI surface used by CatVod/TVBox spiders.  The real CatVod
 * runtime supplies this class; keeping the same binary name in the bridge
 * lets a downloaded classes.dex resolve its superclass without bundling the
 * full TVBox application.
 */
public class Spider {
    public void init(Context context, String extend) throws Exception {}
    public String homeContent(boolean filter) throws Exception { throw unsupported("homeContent"); }
    public String homeVideoContent() throws Exception { throw unsupported("homeVideoContent"); }
    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception { throw unsupported("categoryContent"); }
    public String detailContent(List<String> ids) throws Exception { throw unsupported("detailContent"); }
    public String searchContent(String key, boolean quick) throws Exception { throw unsupported("searchContent"); }
    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception { throw unsupported("playerContent"); }
    public String localSearchContent(String key) throws Exception { throw unsupported("localSearchContent"); }
    public String liveContent(String url) throws Exception { throw unsupported("liveContent"); }
    public String action(String action) throws Exception { throw unsupported("action"); }

    private UnsupportedOperationException unsupported(String method) {
        return new UnsupportedOperationException(method + " is not implemented by this spider");
    }
}
