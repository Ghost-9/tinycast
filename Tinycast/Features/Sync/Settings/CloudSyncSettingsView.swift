import SwiftUI

struct CloudSyncSettingsView: View {
    @Environment(AppCore.self) private var core

    private var state: CloudSyncState { core.cloudSync }
    private var settings: AppSettings { core.settings }
    private var coordinator: CloudSyncCoordinator { core.cloudSyncCoordinator }

    private var isEnabled: Binding<Bool> {
        Binding(get: { settings.cloudSyncEnabled }, set: { coordinator.setEnabled($0) })
    }

    /// A category that runs code asks first, so the switch follows the setting, not the click.
    private func isSyncing(_ category: SyncCategory) -> Binding<Bool> {
        Binding(
            get: { settings.cloudSyncCategories.contains(category) },
            set: { enabled in Task { await coordinator.setCategory(category, enabled: enabled) } })
    }

    private var includesSecrets: Binding<Bool> {
        Binding(
            get: { settings.cloudSyncIncludesSecrets },
            set: { settings.cloudSyncIncludesSecrets = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: isEnabled) {
                    SettingsRowTitle(.iCloudSyncICloudSync, "Sync across your Macs")
                    Text(summary)
                }
                .disabled(!state.isSupported)
            } header: {
                SettingsSectionHeader(.iCloudSyncICloudSync)
            }

            Section {
                ForEach(SyncCategory.allCases) { category in
                    Toggle(isOn: isSyncing(category)) {
                        Text(category.descriptor.label)
                        Text(category.descriptor.detail)
                    }
                    .settingsEnabled(settings.cloudSyncEnabled)
                }
                Toggle(isOn: includesSecrets) {
                    SettingsRowTitle(.iCloudSyncWhatSyncs, "Include API keys and tokens")
                    Text("AI keys, MCP server headers and variables, and extension passwords")
                }
                .settingsEnabled(settings.cloudSyncEnabled)
            } header: {
                SettingsSectionHeader(.iCloudSyncWhatSyncs)
            } footer: {
                Text(
                    "Everything is end-to-end encrypted. Permissions, folder locations, clipboard "
                        + "history, AI chats and what the launcher learns stay on each Mac.")
            }

            if settings.cloudSyncEnabled {
                statusSection
                macsSection
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.iCloudSync)
        .task { await coordinator.syncNow() }
    }

    private var statusSection: some View {
        Section {
            LabeledContent {
                if state.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Sync Now") { Task { await coordinator.syncNow() } }
                        .disabled(state.availability != .available)
                }
            } label: {
                Text("iCloud")
                Text(statusText)
            }
            LabeledContent("Last fetched") { RelativeTimeText(date: state.lastFetch) }
            LabeledContent("Last sent") { RelativeTimeText(date: state.lastSend) }
            if state.heldCount > 0 {
                Label(heldText, systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            SettingsSectionHeader(.iCloudSyncStatus)
        }
    }

    private var macsSection: some View {
        Section {
            ForEach(state.devices) { device in
                LabeledContent {
                    if device.id == state.thisDeviceID {
                        Text("This Mac").foregroundStyle(.secondary)
                    } else {
                        Button("Remove…") { Task { await coordinator.removeDevice(device) } }
                    }
                } label: {
                    Text(device.name)
                    RelativeTimeText(date: device.lastSeen, prefix: "Last seen ")
                }
            }
            LabeledContent {
                Button("Delete…", role: .destructive) {
                    Task { await coordinator.deleteICloudData() }
                }
                .disabled(state.availability != .available)
            } label: {
                SettingsRowTitle(.iCloudSyncMacs, "Delete iCloud Data")
                Text("Turns sync off on every Mac. Nothing on any Mac is deleted.")
            }
        } header: {
            SettingsSectionHeader(.iCloudSyncMacs)
        }
    }

    private var summary: String {
        state.isSupported
            ? "What is ticked below follows you to every Mac signed in to this iCloud account."
            : "This build of Tinycast isn’t signed for iCloud, so it can’t sync."
    }

    private var statusText: String {
        switch state.availability {
        case .off, .checking: "Connecting…"
        case .noAccount: "Sign in to iCloud in System Settings to sync."
        case .restricted: "iCloud is restricted on this Mac."
        case .available: state.isSyncing ? "Syncing…" : "Up to date"
        }
    }

    private var heldText: String {
        let count = state.heldCount
        let subject = count == 1 ? "1 item waits" : "\(count) items wait"
        return "\(subject) for an app, item or shortcut this Mac doesn’t have free yet."
    }
}

/// "5 minutes ago", kept current while the pane is open.
private struct RelativeTimeText: View {
    let date: Date?
    var prefix = ""

    var body: some View {
        if let date {
            TimelineView(.everyMinute) { _ in
                Text(prefix + date.formatted(.relative(presentation: .named)))
            }
        } else {
            Text("Never")
        }
    }
}
