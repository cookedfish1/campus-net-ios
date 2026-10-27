隐藏宿主模式：登录过程不再弹窗。

**做法**
- 1×1 的 WKWebView 以 `alpha 0.01` 挂在根视图 background（不能用 `isHidden`，
  WebKit 会判定不可见而节流甚至挂起 WebContent 进程）
- 注入改由 **Swift 定时器每 250ms `evaluateJavaScript`** 驱动；
  不用 JS `setInterval`——非可见 webview 里它会被限到 ≥1 秒
- 提交后每 800ms 探测 204，成功后静默
- **20 秒没成功 → 自动弹出可见门户页转人工**（验证码 / 页面异常）

日志里对应：`登录中…` → `已提交：submitted|action=...` → `✓ 登录成功`；
若转人工会出现 `转为人工处理：<原因>`。

v0.2.0 的提速与上下线开关、5G/2.4G 切换都在。