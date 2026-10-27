import Foundation
import NetworkExtension

/// 5G / 2.4G 切换。
///
/// 依赖 Hotspot Configuration 能力（com.apple.developer.networking.HotspotConfiguration）。
/// 该能力需要**付费开发者账号**在 Xcode 里给 target 勾选，并反映到 provisioning profile；
/// 免费签名（AltStore / Sideloadly）里没有它，调用会返回错误，此处只把错误原样报给界面。
final class HotspotManager {
    static let shared = HotspotManager()

    enum JoinError: LocalizedError {
        case failed(String)
        case missingEntitlement

        var errorDescription: String? {
            switch self {
            case .failed(let m):        return m
            case .missingEntitlement:   return "缺少 Hotspot Configuration 能力（需付费账号签名）"
            }
        }
    }

    /// 当前系统认为已关联的 SSID（无定位权限时为空）
    var currentSSID: String? {
        NEHotspotNetwork.fetchCurrent { _ in }
        return nil
    }

    func join(ssid: String) async throws {
        let config = NEHotspotConfiguration(ssid: ssid)
        config.joinOnce = false

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                guard let error = error as NSError? else {
                    cont.resume()
                    return
                }
                // 已经连着同一个网络，视为成功
                if error.domain == NEHotspotConfigurationErrorDomain,
                   error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    cont.resume()
                    return
                }
                if error.localizedDescription.lowercased().contains("entitlement") {
                    cont.resume(throwing: JoinError.missingEntitlement)
                    return
                }
                cont.resume(throwing: JoinError.failed(error.localizedDescription))
            }
        }
    }
}
