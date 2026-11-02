import SwiftUI
import AppKit

/// 已知输出设备及其独立配置。设备配置本身始终按 UID 自动保存；
/// 这个面板负责展示、立即保存，以及把旧设备配置复用到当前设备。
struct DeviceProfilesView: View {
    @ObservedObject var state: AppState
    var snapshotMode: Bool = false

    private var devices: [KnownDeviceProfile] {
        state.knownDevices.sorted {
            if $0.uid == state.currentDeviceUID { return true }
            if $1.uid == state.currentDeviceUID { return false }
            return $0.lastSavedAt > $1.lastSavedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("已知设备配置")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Button {
                    state.showDeviceProfiles = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            if devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "headphones")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("还没有保存的设备配置")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshotMode {
                VStack(spacing: 7) {
                    ForEach(devices.prefix(3)) { device in
                        deviceRow(device)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(devices) { device in
                            deviceRow(device)
                        }
                    }
                }
            }

            Divider()
            HStack(spacing: 6) {
                if let notice = state.deviceConfigNotice {
                    Text(notice)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("完成") { state.showDeviceProfiles = false }
                    .buttonStyle(.link)
                    .font(.system(size: 10))
            }
        }
        .padding(14)
        .frame(width: 430, height: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func deviceRow(_ device: KnownDeviceProfile) -> some View {
        let current = device.uid == state.currentDeviceUID
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: current ? "headphones.circle.fill" : "headphones.circle")
                .font(.system(size: 17))
                .foregroundStyle(current ? Color.orange : Color.secondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(current ? state.deviceName : device.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if current {
                        Text("当前")
                            .font(.system(size: 8, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.16)))
                            .foregroundStyle(Color.orange)
                    }
                }
                Text(state.deviceConfigSummary(for: device))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("保存于 \(dateText(device.lastSavedAt))")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            if current {
                Button("立即保存") { state.saveCurrentDeviceConfiguration() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button("载入") { state.applyDeviceConfiguration(from: device) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(current ? Color.orange.opacity(0.08) : Color.gray.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(current ? Color.orange.opacity(0.28) : Color.gray.opacity(0.14), lineWidth: 0.8)
        )
        .contextMenu {
            if current {
                Button("立即保存当前配置") { state.saveCurrentDeviceConfiguration() }
            } else {
                Button("载入到当前设备") { state.applyDeviceConfiguration(from: device) }
                Button("删除保存的配置", role: .destructive) {
                    state.deleteDeviceConfiguration(device)
                }
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        if date == .distantPast { return "尚未保存" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}
