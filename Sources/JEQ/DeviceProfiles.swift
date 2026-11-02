import Foundation

/// 连接过的输出设备及其最后保存时间。实际 EQ 配置仍存放在每台设备自己的
/// `state.v2.<UID>` 中，这个记录只负责让用户看见并管理已知设备。
struct KnownDeviceProfile: Codable, Identifiable, Equatable {
    var uid: String
    var name: String
    var lastUsedAt: Date
    var lastSavedAt: Date

    var id: String { uid }
}
