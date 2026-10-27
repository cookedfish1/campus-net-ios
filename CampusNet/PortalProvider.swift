import Foundation

/// 门户策略：换一套校园网就加一个实现，界面不动
protocol PortalProvider {
    var name: String { get }
    /// CSS 选择器（逗号分隔，按优先级）
    var userSelectors: String { get }
    var passwordSelectors: String { get }
    var formSelectors: String { get }
    /// 成功页特征
    var successMarkers: [String] { get }
    /// 下线接口
    var logoutURL: String { get }
}

struct RenAiProvider: PortalProvider {
    let name = "仁爱宿舍（ailk）"
    let userSelectors = "#Wp_user, input[name=userName], #username, input[name=username]"
    let passwordSelectors = "#Wp_password, input[name=userPwd], #pwd, input[name=password]"
    let formSelectors = "#loginForm, form"
    let successMarkers = ["logoutLeave", "portalLoginRedirect"]
    let logoutURL = "https://111.32.9.98:28090/portalLogout.wlan"
}

/// 教学楼 TJRAC：字段与接口待抓包确认，先占位
struct TJRACProvider: PortalProvider {
    let name = "教学楼（TJRAC）"
    let userSelectors = "#username, input[name=userName], input[name=username]"
    let passwordSelectors = "#pwd, input[name=password], input[name=userPwd]"
    let formSelectors = "form"
    let successMarkers = ["logout", "success"]
    let logoutURL = ""
}
