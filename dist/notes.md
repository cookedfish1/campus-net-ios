最小验证版本：确认 iOS 上能否用 WKWebView 完成该校园网门户的登录。

- 探测 204 探针取门户跳转（禁用自动跳转以拿到 Location）
- WKWebView 加载门户并放行自签证书
- 注入 JS 填 `#Wp_user` / `#Wp_password` 后提交
- 判定：成功页特征（logoutLeave / portalLoginRedirect）+ 204 复核
- 「获取日志文件」可导出 campusnet.log

**未签名 IPA**，需用 AltStore / Sideloadly 等以自己的 Apple ID 重签后安装。
免费账号签名 7 天过期。