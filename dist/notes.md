真机日志显示：登录链路本身是通的，19 秒全耗在等门户页的 banner 图片（`didFinish` 等同 `window.onload`）。

**提速**
- 不再依赖 `didFinish`，改为 `atDocumentEnd` 注入自轮询脚本，一出现输入框立即填表提交
- 内容拦截器屏蔽图片
- 放行判定轮询 2s → 0.8s

**补全**
- 「已上线」开关：下线复用登录时保存的会话（cookie + `#formLogout` 字段）
- 5G / 2.4G 切换（`NEHotspotConfigurationManager`，需 Hotspot Configuration 能力）
- `PortalProvider` 协议，TJRAC 占位

预期登录耗时从约 22 秒降到 3~5 秒。