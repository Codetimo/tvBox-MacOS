# Android Spider Bridge

这是一个无第三方依赖的 Android `Service`，把 TVBox/CatVod 的 `classes.dex`
Spider 包加载到应用进程，并在 `127.0.0.1:19190` 提供认证的 HTTP 接口。
服务应由宿主在自己的生命周期中通过 `ACTION_START` 启动，并在会话结束时
调用 `stopService`。`android:stopWithTask="true"` 也会在宿主任务被移除时停止它。

## 启动参数

`Intent` action 使用 `com.tvbox.bridge.START`，参数如下：

| extra | 必填 | 说明 |
| --- | --- | --- |
| `spider_url` | 是 | `http`/`https` Spider 包地址（支持伪装成 jpg 的 zip/dex） |
| `spider_md5` | 否 | 32 位 MD5；不匹配会拒绝加载 |
| `spider_class` | 否 | 如 `com.github.catvod.spider.AiNewHuBanGuard` 或 `csp_AiNewHuBanGuard` |
| `spider_ext` | 否 | 传给 `init(Context, String)` 的站点扩展配置 |
| `port` | 否 | 默认 `19190` |
| `token` | 否 | 随机认证 token；宿主应显式传入并保存 |

下载包缓存到应用 `codeCacheDir/tvbox-spider`，限制 64 MiB，使用临时文件和
MD5 校验后才替换缓存。包内 `assets/*.so` 会按当前 ARM ABI 解压并尝试加载。
不支持在 x86 模拟器上运行 ARM native Spider。

## HTTP 协议

所有请求必须带 `X-TVBox-Token: <token>` 或 `Authorization: Bearer <token>`。
仅监听 IPv4/IPv6 loopback，连接与读取超时 30 秒，请求体限制 2 MiB。

```text
GET  /health
POST /api/search  {"keyword":"蜘蛛侠","quick":false,"spiderClass":"csp_AiNewHuBanGuard","ext":"..."}
POST /api/detail  {"ids":["123"]}
POST /api/player  {"flag":"线路1","id":"123","vipFlags":[]}
```

响应统一为 JSON。成功时 `ok=true`，`data` 是 Spider 返回的 JSON 对象/数组；
非 JSON 的返回值会保留为字符串。Spider 抛异常或返回空值时返回 `502`，不会
伪造空的成功结果。`/health` 包含 `engine=android-dex`、`state` 和实际端口。

## 编译

不需要 Gradle 依赖。使用 Android SDK 的 `android.jar` 编译，再用 d8/dx 打成
宿主 APK 的 dex（`Bridge/src` 可直接纳入宿主 Android module）：

```sh
javac -source 8 -target 8 \
  -cp "$ANDROID_HOME/platforms/android-34/android.jar" \
  -d build/classes $(find src/main/java -name '*.java')
```

`org.json`、`android.app.Service`、`dalvik.system.DexClassLoader` 都来自系统
框架，不要添加 Maven 依赖。Dex 中的 Spider 仍可能依赖 QuickJS 或特定 ARM
native 符号；这类缺失会通过 `/health`/接口错误返回，不能在桥接层假装支持。
