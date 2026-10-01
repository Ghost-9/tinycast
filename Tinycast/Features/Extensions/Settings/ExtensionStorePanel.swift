import SwiftUI

/// The Raycast Store's search, and an install button per result.
struct ExtensionStorePanel: View {
    let onClose: () -> Void
    @Environment(AppCore.self) private var core

    @State private var query = ""
    @State private var results: [ExtensionListing] = []
    @State private var searchFailure: String?
    @State private var searching = false
    @State private var searched = false
    @State private var installing: [String: ExtensionInstaller.Progress] = [:]
    @State private var failures: [String: String] = [:]
    @State private var installed: Set<String> = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ExtensionSettingsEditorHeader(
                title: "Search Extensions",
                subtitle: "The Raycast Store's extensions arrive built, so they install as they are.")
            // The same borderless field the panes use, rather than a bordered capsule of its own.
            SettingsFilterField(prompt: "Search extensions…", query: $query)
            content
            // The list scrolls right up to the footer without it, cutting the last row.
            Divider()
            footer
        }
        .padding(Theme.Spacing.dialogInset)
        .frame(width: 620, height: 560)
        .extensionSettingsEditorPanelSurface()
        .onChange(of: query) { _, value in scheduleSearch(value) }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState
        } else if searching && results.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text("Searching…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let searchFailure {
            placeholder(searchFailure)
        } else if results.isEmpty && searched {
            placeholder("Nothing matches “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(results) { listing in
                        StoreRow(
                            listing: listing,
                            state: state(for: listing),
                            onInstall: { install(listing) })
                        Divider().opacity(0.4)
                    }
                }
                .hideNativeScrollers()
            }
            .overflowFade()
            .thinScrollbar()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Not a bare line of text in a tall empty panel: says what to do and what it will search.
    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search for an extension")
                .font(.headline)
            Text(
                "By name, or by what it does — \u{201C}colour\u{201D}, \u{201C}github\u{201D}, \u{201C}window\u{201D}."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Spacer()
            // Escape, not Return: Return belongs to the search field while typing.
            Button("Done", action: onClose)
                .buttonStyle(
                    ExtensionSettingsEditorButtonStyle(role: .cancel, fillsWidth: false)
                )
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - State

    private func state(for listing: ExtensionListing) -> StoreRow.State {
        if installed.contains(listing.name) { return .installed }
        if let progress = installing[listing.id] { return .installing(progress.message) }
        if let failure = failures[listing.id] { return .failed(failure) }
        if core.extensions.installed.contains(where: { $0.manifest.name == listing.name }) {
            return .alreadyInstalled
        }
        return .idle
    }

    // MARK: - Searching

    /// Debounced: every keystroke would otherwise be a request to someone else's API.
    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            searchFailure = nil
            searched = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search(trimmed)
        }
    }

    private func search(_ trimmed: String) async {
        searching = true
        defer {
            searching = false
            searched = true
        }
        do {
            let found = try await ExtensionStoreClient().search(trimmed)
            guard !Task.isCancelled else { return }
            (results, searchFailure) = (found, nil)
        } catch {
            guard !Task.isCancelled else { return }
            (results, searchFailure) = ([], error.localizedDescription)
        }
    }

    // MARK: - Installing

    private func install(_ listing: ExtensionListing) {
        failures[listing.id] = nil
        installing[listing.id] = .downloading
        Task {
            do {
                try await core.extensions.install(
                    listing,
                    onProgress: { progress in
                        Task { @MainActor in installing[listing.id] = progress }
                    })
                installed.insert(listing.name)
            } catch {
                failures[listing.id] = error.localizedDescription
            }
            installing[listing.id] = nil
        }
    }
}

/// One search result: what it is, who made it, and the button that installs it.
private struct StoreRow: View {
    enum State: Equatable {
        case idle
        case installing(String)
        case installed
        case alreadyInstalled
        case failed(String)
    }

    let listing: ExtensionListing
    let state: State
    let onInstall: () -> Void
    @Environment(\.isDarkAppearance) private var isDark

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            ExtensionIconView(
                resolved: listing.iconURL(isDark: isDark).map {
                    ExtensionImage.Resolved(source: .remote($0))
                },
                size: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(listing.title).font(.body.weight(.medium))
                if !listing.summary.isEmpty {
                    Text(listing.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(listing.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if case .failed(let message) = state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            action
        }
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .idle:
            Button("Install", action: onInstall)
        case .installing(let message):
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize()
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        case .alreadyInstalled:
            Button("Reinstall", action: onInstall)
                .help("Already installed. Reinstalling replaces it with the store's copy.")
        case .failed:
            Button("Retry", action: onInstall)
        }
    }
}
