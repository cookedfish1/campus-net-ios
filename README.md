# CampusNet (iOS)

天津仁爱学院校园网（`CMCC_RenAi_5G` / `CMCC_RenAi_2.4G`）自动认证的 iOS 客户端。

当前是**最小验证版本**：只做「探测门户 → 浏览器填表提交 → 判定结果 → 导出日志」，
用来确认 iOS 上把登录交给 `WKWebView` 是否可行（Windows 版用 Playwright + Edge，
见 [CampusAutoLogin](https://github.com/cookedfish1)）。

## 为什么用 WKWebView

该门户对非浏览器客户端一律返回 HTTP 500，Windows 版逐项排除过密码、验证码、cookie、
请求头、端口、`Expect: 100-continue` 之后，确认是客户端层面的指纹差异，最终改用真实浏览器解决。
iOS 上对应的做法就是 `WKWebView`（Safari 同款 WebKit），并放行门户的自签证书。

## 流程

```
点「上线」
  ├─ URLSession 请求 http://connect.rom.miui.com/generate_204（禁用自动跳转）
  │    204 → 已在线，结束
  │    302 → 取 Location（含 wlanuserip / wlanacname / ssid / usermac）
  ↓
弹出 WKWebView 加载门户（自动放行自签证书）
  ↓ didFinish
注入 JS：填 #Wp_user / #Wp_password → document.getElementById('loginForm').submit()
  ↓ 再次 didFinish
读 outerHTML：含 logoutLeave / portalLoginRedirect → 成功
             否则用 204 探针复核
  ↓
界面显示结果；日志同时写内存与文件
```

## 界面

- 账号 / 密码输入（账户用 `@AppStorage` 记住）
- 「上线（自动登录）」按钮
- **「获取日志文件」**：`ShareLink` 导出 `campusnet.log`（沙盒 Documents）
- 「清空日志」
- 最近日志滚动区（等宽字体，可选中）

登录过程中门户页面是**可见**的——出验证码时可以直接手填，这是最小验证阶段刻意保留的。

## 本地构建

需要 macOS + Xcode：

```bash
brew install xcodegen
xcodegen generate
open CampusNet.xcodeproj
```

在 Xcode 里选自己的 Team 签名后真机运行。

## 构建 IPA

仓库自带 `.github/workflows/build-ipa.yml`：推送到 `main` 或手动触发后，
在 macOS runner 上生成**未签名** `CampusNet-unsigned.ipa`，作为 artifact 上传。

未签名 IPA 不能直接安装，需要用 AltStore / Sideloadly 之类工具用你自己的 Apple ID 重签：

- 免费账号：签名 7 天过期，需重签
- 付费开发者账号：1 年

## 已知风险 / 待验证

1. **WKWebView 是否也被 WAF 拦**——这是整个方案的前提。理论上 Safari 引擎与浏览器指纹一致，
   但必须实测通过才算数。
2. 门户端口会在 28090 / 18090 之间轮换，目前依赖页面自身的跳转，未做硬编码。
3. 验证码不做 OCR：失败时日志会记录服务器原文，用户可在弹层里手动填。
4. `NSAllowsArbitraryLoads` 仅为校园网 http + 自签证书放行，上架前需改成精确的例外域名。

## 后续

- 5G / 2.4G 切换：`NEHotspotConfigurationManager`（需 Hotspot Configuration 能力）
- 下线：复用登录会话 cookie + `#formLogout` 字段 POST `portalLogout.wlan?isCloseWindow=N`
- TJRAC（教学楼内外）：抽象 `PortalProvider` 协议，另写一个实现
