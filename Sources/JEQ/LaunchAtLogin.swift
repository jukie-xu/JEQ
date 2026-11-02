import Foundation
import ServiceManagement

/// 开机启动。
/// 优先用系统登录项（SMAppService.mainApp）；本产物是 ad-hoc 签名，
/// 某些系统上 register() 会失败，此时自动退回用户级 LaunchAgent，
/// 保证「打开开关就一定会随登录启动」，而不是弹一个错误了事。
enum LaunchAtLogin {
    static let label = "com.jeq.app"
    static let legacyLabel = "com.subeq.app"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var legacyAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static var isEnabled: Bool {
        if FileManager.default.fileExists(atPath: agentURL.path) { return true }
        return systemLoginItemEnabled
    }

    static var systemLoginItemEnabled: Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        return false
    }

    /// 当前实际生效的方式，用于界面提示
    static var mechanismDescription: String {
        if FileManager.default.fileExists(atPath: agentURL.path) { return "LaunchAgent" }
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return "系统登录项"
            case .requiresApproval: return "系统登录项（待系统允许）"
            default: break
            }
        }
        return "未开启"
    }

    /// 返回 nil 表示成功；否则是给用户看的错误说明
    @discardableResult
    static func set(_ on: Bool) -> String? {
        if on { return enable() }
        return disable()
    }

    private static func enable() -> String? {
        removeAgent(at: legacyAgentURL)

        if #available(macOS 13.0, *) {
            do {
                let status = SMAppService.mainApp.status
                if status != .enabled && status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
                // 系统登录项成功后不再需要自建代理，避免登录时启动两份
                removeAgent(at: agentURL)
                return nil
            } catch let smError {
                // register 失败（常见于 ad-hoc 签名）→ 退回 LaunchAgent
                if SMAppService.mainApp.status == .enabled {
                    removeAgent(at: agentURL)
                    return nil
                }
                do {
                    try installAgent()
                    return nil
                } catch let agentError {
                    return "系统登录项失败（\(smError.localizedDescription)），"
                        + "后备方式也失败（\(agentError.localizedDescription)）"
                }
            }
        }

        do {
            try installAgent()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func disable() -> String? {
        var message: String?

        if #available(macOS 13.0, *) {
            do {
                let status = SMAppService.mainApp.status
                if status == .enabled || status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                message = error.localizedDescription
            }
        }

        removeAgent(at: agentURL)
        removeAgent(at: legacyAgentURL)

        if isEnabled { return message ?? "未能关闭开机启动" }
        return nil
    }

    // MARK: - LaunchAgent 后备方案

    private static func installAgent() throws {
        let exec = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exec],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
    }

    private static func removeAgent(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
