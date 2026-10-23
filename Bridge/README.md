# Android Spider Bridge

这是一个 Android `Service`，把 TVBox/CatVod 的 `classes.dex`
Spider 包加载到应用进程，并在 `127.0.0.1:19190` 提供认证的 HTTP 接口。
服务应由宿主在自己的生命周期中通过 `ACTION_START` 启动，并在会话结束时
调用 `stopService`。`android:stopWithTask="true"` 也会在宿主任务被移除时停止它。

## 启动参数

`Intent` action 使用 `com.tvbox.bridge.START`，参数如下：

| extra | 必填 | 说明 |
| --- | --- | --- |
| `spider_url` | 否 | `http`/`https` Spider 包地址（支持伪装成 jpg 的 zip/dex） |
| `spider_md5` | 否 | 32 位 MD5；不匹配会拒绝加载 |
| `spider_class` | 否 | 如 `com.github.catvod.spider.AiNewHuBanGuard` 或 `csp_AiNewHuBanGuard` |
| `spider_ext` | 否 | 传给 `init(Context, String)` 的站点扩展配置 |
| `port` | 否 | 默认 `19190` |
| `token` | 否 | 随机认证 token；宿主应显式传入并保存 |

下载包缓存到应用 `codeCacheDir/tvbox-spider`，限制 64 MiB，使用临时文件和
MD5 校验（提供时）后按 SHA-256 内容版本保存。DEX 和 `.so` 使用同一版本目录，
不会原位覆盖已加载的原生库。相同内容的不同 URL / MD5 别名共享同一个 loader 与凭据状态。无 MD5 的地址在进程首次使用和之后每 5 分钟按需重新下载验证；
内容不变时复用 loader，活动扫码任务完成前延后更新。重验证下载或校验失败时本次请求明确失败，
不会静默回退旧包；已加载的旧版本文件保留，未中断既有调用。包内 `assets/*.so` 按当前 ARM ABI 解压。
不支持在 x86 模拟器上运行 ARM native Spider。

缓存仅在 Android 进程首次启动、加载任何 Spider 之前清理，按最近使用保留最多 8 个版本、
合计 512 MiB；同时清理失效引用与遗留临时文件。服务在同一进程中重建不会清理 native 文件。
运行期最多 16 个版本、1 GiB 缓存，为每次并发下载预留 256 MiB（包、原生库与优化空间），
因此会在真正耗尽磁盘预算前拒绝新增下载；已经验证的固定 MD5 缓存仍可复用。
并发下载预留临时不足时最多等待 5 秒，随后返回繁忙错误，不触发进程恢复。
单会话最多 256 个包别名、512 次 engine 构造（包括失败构造和凭据更新后的重建）。
达到预算会标记 `restartRequired`，由宿主按恢复预算替换进程；不会在运行中删除已加载版本。

## HTTP 协议

所有请求必须带 `X-TVBox-Token: <token>` 或 `Authorization: Bearer <token>`。
仅监听 `127.0.0.1`，请求读取超时 5 秒，请求体限制 2 MiB。
HTTP 解析与健康检查独立于 Spider 执行线程池；执行池有 16 个线程、24 个排队位置，
同包最多接收 8 个请求、同时执行 2 个；等待同包执行名额的请求不占业务线程。
请求从提交开始 20 秒超时，返回 `504`；容量耗尽返回 `503`。
任一请求超时会熔断该包 30 秒，取消它尚未执行的队列；已开始的任务请求中断，
但配额直到实际执行退出才释放。超时后 5 秒任务仍未退出，则健康接口报告
`ready=false`、`state=recovery-required`、`restartRequired=true`，停止接收新的业务任务。
Java 无法安全终止卡死的 JNI。宿主必须用 `am force-stop` 替换整个 Bridge 进程；
仅停止 Service 无法保证释放原生线程。宿主恢复预算耗尽时明确报告不可用，避免无限重启。

```text
GET  /health
POST /api/search  {"keyword":"蜘蛛侠","quick":false,"spiderClass":"csp_AiNewHuBanGuard","ext":"..."}
POST /api/detail  {"ids":["123"]}
POST /api/player  {"flag":"线路1","id":"123","vipFlags":[]}
```

响应统一为 JSON。成功时 `ok=true`，`data` 是 Spider 返回的 JSON 对象/数组；
非 JSON 的返回值会保留为字符串。Spider 抛异常或返回空值时返回 `502`，不会
伪造空的成功结果。响应包含 `request_id`；日志记录站点类名、接口、耗时、状态及错误类别，
不输出第三方异常消息、原始调试文本、Cookie 或 URL。第三方代码直接写 Android 日志的行为不受此适配层控制。
`/health` 包含 `engine=android-dex`、`state`、实际端口、`restartRequired`、
`activeOperations`、`loadedPackageVersions` 和 `constructedEngines`，不暴露包 URL。

## 编译

使用已准备的 Android 35 / JDK 17 运行时：

```sh
scripts/test_spider_bridge.sh
scripts/build_spider_bridge.sh
```

纯 JDK 回归覆盖限流、总时限、同包队列调度、熔断、不可中断任务恢复标记、
冷启动缓存清理、运行期容量拒绝及内容缓存更新，不需要运行模拟器；APK 构建使用
`android.jar`、D8、aapt2 和签名工具。CI 对这两项单独执行。可以通过
`TVBOX_JDK_DIR` / `TVBOX_ANDROID_SDK_DIR` 指定已有工具链。

`org.json`、`android.app.Service`、`dalvik.system.DexClassLoader` 来自 Android 框架。
打包脚本额外提供 CatVod 宿主常用的 OkHttp、Okio、Gson、Jsoup；真实 Spider 仍可能依赖
特定 ARM native 符号。测试通过或健康接口 ready 不能替代真实站点搜索、详情、播放与扫码验收。
