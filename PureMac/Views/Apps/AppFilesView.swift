import SwiftUI

/// View-side grouping of discovered leftovers into CleanMyMac-style buckets.
/// Purely presentational — AppState's flat `discoveredFiles` stays the source
/// of truth so the removal/selection logic is untouched.
enum LeftoverGroup: String, CaseIterable, Identifiable {
    case application = "Application"
    case caches = "Caches"
    case appSupport = "Application Support"
    case preferences = "Preferences"
    case logs = "Logs"
    case containers = "Containers"
    case launchAgents = "Launch Agents"
    case other = "Other Files"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .application: return "app.fill"
        case .caches: return "internaldrive.fill"
        case .appSupport: return "shippingbox.fill"
        case .preferences: return "gearshape.fill"
        case .logs: return "doc.text.fill"
        case .containers: return "cube.box.fill"
        case .launchAgents: return "bolt.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: Color {
        switch self {
        case .application: return Tint.blue
        case .caches: return Tint.orange
        case .appSupport: return Tint.purple
        case .preferences: return Tint.cyan
        case .logs: return Tint.yellow
        case .containers: return Tint.pink
        case .launchAgents: return Tint.red
        case .other: return Tint.green
        }
    }

    static func categorize(_ url: URL) -> LeftoverGroup {
        let path = url.path
        if path.hasSuffix(".app") { return .application }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Application Support/") { return .appSupport }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Logs/") || path.contains("/DiagnosticReports/") { return .logs }
        if path.contains("/Containers/") || path.contains("/Group Containers/") { return .containers }
        if path.contains("/LaunchAgents/") || path.contains("/LaunchDaemons/") { return .launchAgents }
        return .other
    }
}

struct AppFilesView: View {
    @EnvironmentObject var appState: AppState

    @State private var collapsedGroups: [String: Set<LeftoverGroup>] = [:]
    @State private var showBulkConfirmation = false
    @State private var pendingRemoval: Set<URL> = []
    /// One-pass size cache so group headers and the selected-size counter
    /// don't re-stat the disk on every render.
    @State private var sizeCache: [URL: Int64] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedApps: [InstalledApp] {
        let snapshots = appState.selectedAppSnapshots
        return appState.selectedAppBundleIDs.compactMap { bundleID in
            snapshots[bundleID] ?? appState.installedApps.first { $0.bundleIdentifier == bundleID }
        }.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    private var totalSelectedSize: Int64 {
        appState.selectedFiles.reduce(Int64(0)) { total, url in
            total + (cachedSize(url) ?? 0)
        }
    }

    private func groupedFiles(for urls: [URL]) -> [(group: LeftoverGroup, urls: [URL])] {
        let buckets = Dictionary(grouping: urls, by: LeftoverGroup.categorize)
        return LeftoverGroup.allCases.compactMap { group in
            guard let groupURLs = buckets[group], !groupURLs.isEmpty else { return nil }
            return (group, groupURLs)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selectedApps.isEmpty {
                EmptyStateView(
                    "Select an App",
                    systemImage: "cursorarrow.click.2",
                    description: "Select one or more apps from the list to see related files across your system.",
                    tint: Tint.purple
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(selectedApps) { app in
                            appSection(for: app)
                        }

                        if appState.isScanningAppFiles {
                            scanningPlaceholderCard
                        }
                    }
                    .padding(16)
                }

                actionBar
            }
        }
        .task(id: appState.discoveredFiles) {
            let urls = appState.discoveredFiles
            let task = Task.detached(priority: .utility) {
                var sizes: [URL: Int64] = [:]
                for url in urls {
                    guard !Task.isCancelled else { break }
                    sizes[url] = FileSizeCalculator.size(of: url) ?? 0
                }
                return sizes
            }
            let sizes = await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            guard !Task.isCancelled else { return }
            sizeCache = sizes
        }
        .disabled(appState.isRemovingAppFiles)
        .confirmationDialog("Remove selected app files?", isPresented: $showBulkConfirmation, titleVisibility: .visible) {
            Button("Remove \(pendingRemoval.count) files", role: .destructive) {
                appState.removeSelectedFiles(confirmedURLs: pendingRemoval)
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("PureMac will move the selected app and related files to the Trash. Items requiring administrator authorization may be permanently deleted. Review the selection before continuing.")
        }
        .onChange(of: appState.removalNeedsFullDiskAccess) { needs in
            guard needs else { return }
            let toRetry = appState.lastFailedRemovalURLs
            let names = appState.lastFailedRemovalAppNames
            let items = toRetry.map { appState.makeUninstallCleanableItem(for: $0) }
            appState.removalError = nil
            appState.removalNeedsFullDiskAccess = false
            appState.lastFailedRemovalURLs = []
            appState.lastFailedRemovalAppNames = []
            appState.requestFullDiskAccessAndRetry(
                items: items,
                context: .uninstall(appNames: names, failedCount: items.count)
            )
        }
        .alert("Removal Failed", isPresented: Binding(
            get: { appState.removalError != nil && !appState.removalNeedsFullDiskAccess },
            set: {
                if !$0 {
                    appState.removalError = nil
                    appState.removalNeedsFullDiskAccess = false
                }
            }
        )) {
            Button("OK", role: .cancel) {
                appState.removalError = nil
                appState.removalNeedsFullDiskAccess = false
            }
        } message: {
            Text(appState.removalError ?? "")
        }
    }

    // MARK: - App Section

    private func appSection(for app: InstalledApp) -> some View {
        let files = appState.discoveredFilesByApp[app.bundleIdentifier] ?? []
        let appSize = files.reduce(Int64(0)) { $0 + (cachedSize($1) ?? 0) }
        let isActivelyScanning = appState.isScanningAppFiles && appState.currentlyScanningBundleID == app.bundleIdentifier

        return VStack(alignment: .leading, spacing: 10) {
            appHeaderCard(app: app, files: files, size: appSize, isScanning: isActivelyScanning)

            if !isActivelyScanning {
                if files.isEmpty {
                    Text(String(format: String(localized: "No additional files found for %@."), app.appName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else {
                    let grouped = groupedFiles(for: files)
                    ForEach(grouped, id: \.group) { entry in
                        DisclosureGroup(isExpanded: groupExpansionBinding(app.bundleIdentifier, group: entry.group)) {
                            VStack(spacing: 2) {
                                ForEach(entry.urls, id: \.self) { fileURL in
                                    FileRow(
                                        fileURL: fileURL,
                                        isSelected: fileSelectionBinding(for: fileURL),
                                        fileSize: cachedSize(fileURL),
                                        onRemove: { removeSingleFile(fileURL) }
                                    )
                                    .transition(
                                        reduceMotion
                                            ? .opacity
                                            : .asymmetric(
                                                insertion: .opacity,
                                                removal: .move(edge: .leading).combined(with: .opacity)
                                            )
                                    )
                                }
                            }
                            .padding(.leading, 12)
                        } label: {
                            groupHeader(entry.group, urls: entry.urls)
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .id(app.bundleIdentifier)
    }

    // MARK: - App Header Card

    private func appHeaderCard(app: InstalledApp, files: [URL], size: Int64, isScanning: Bool) -> some View {
        CardSurface(padding: 14, tint: Tint.purple) {
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.appName)
                            .font(.system(size: 15, weight: .bold))
                        Text(app.bundleIdentifier)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else if !files.isEmpty {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.system(size: 15, weight: .bold))
                                .monospacedDigit()
                            Text(filesCountText(count: files.count))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                if !files.isEmpty {
                    HStack(spacing: 8) {
                        Button("Select All") {
                            appState.selectedFiles.formUnion(files)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Deselect All") {
                            appState.selectedFiles.subtract(files)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Scanning Placeholder Card

    private var scanningPlaceholderCard: some View {
        let scanningApp = appState.currentlyScanningBundleID.flatMap { bundleID in
            appState.selectedAppSnapshots[bundleID] ?? appState.installedApps.first { $0.bundleIdentifier == bundleID }
        }

        return CardSurface(padding: 14, tint: Tint.blue) {
            HStack(spacing: 12) {
                if let icon = scanningApp?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let name = scanningApp?.appName {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(
                        String(
                            format: String(localized: "Scanning %lld of %lld apps..."),
                            Int64(min(appState.scansCompleted + 1, appState.scansTotal)),
                            Int64(appState.scansTotal)
                        )
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if reduceMotion {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    SearchPulse()
                        .scaleEffect(0.6)
                }
            }
        }
    }

    // MARK: - Group Header

    private func groupHeader(_ group: LeftoverGroup, urls: [URL]) -> some View {
        let groupSize = urls.reduce(Int64(0)) { $0 + (cachedSize($1) ?? 0) }
        let allSelected = urls.allSatisfy { appState.selectedFiles.contains($0) }

        return HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { selected in
                    if selected {
                        appState.selectedFiles.formUnion(urls)
                    } else {
                        appState.selectedFiles.subtract(urls)
                    }
                }
            )) {
                EmptyView()
            }
            .toggleStyle(AnimatedCheckboxStyle())
            .labelsHidden()

            IconTile(systemName: group.icon, tint: group.tint, size: 22, corner: 6)
            Text(LocalizedStringKey(group.rawValue))
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(urls.count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: groupSize, countStyle: .file))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func groupExpansionBinding(_ bundleID: String, group: LeftoverGroup) -> Binding<Bool> {
        Binding(
            get: { !(collapsedGroups[bundleID]?.contains(group) ?? false) },
            set: { expanded in
                let change = {
                    var set = collapsedGroups[bundleID] ?? []
                    if expanded {
                        set.remove(group)
                    } else {
                        set.insert(group)
                    }
                    collapsedGroups[bundleID] = set
                }
                if reduceMotion {
                    change()
                } else {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { change() }
                }
            }
        )
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Select All") {
                appState.selectedFiles = Set(appState.discoveredFiles)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Deselect All") {
                appState.selectedFiles.removeAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if !appState.selectedFiles.isEmpty {
                Button(role: .destructive) {
                    pendingRemoval = appState.selectedFiles
                    showBulkConfirmation = true
                } label: {
                    Text(removeFilesLabel)
                }
                .buttonStyle(GlowProminentButtonStyle(tint: Tint.red, gradient: TintGradient.destructive))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .trailing).combined(with: .opacity)
                )
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                   value: appState.selectedFiles.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    // MARK: - Helpers

    private func filesCountText(count: Int) -> String {
        String(format: String(localized: "%lld files"), Int64(count))
    }

    private var removeFilesLabel: String {
        String(
            format: String(localized: "Remove %lld files (%@)"),
            Int64(appState.selectedFiles.count),
            ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
        )
    }

    private func fileSelectionBinding(for url: URL) -> Binding<Bool> {
        Binding(
            get: { appState.selectedFiles.contains(url) },
            set: { selected in
                if selected {
                    appState.selectedFiles.insert(url)
                } else {
                    appState.selectedFiles.remove(url)
                }
            }
        )
    }

    private func cachedSize(_ url: URL) -> Int64? {
        sizeCache[url]
    }

    private func removeSingleFile(_ url: URL) {
        appState.removeSelectedFiles(confirmedURLs: [url])
    }
}

/// Magnifier over expanding sonar rings — the "actively searching" beat for
/// the related-files scan. Only built when Reduce Motion is off.
private struct SearchPulse: View {
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .stroke(Tint.blue.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulse ? 1.8 : 1.0)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(
                        .easeOut(duration: 1.4)
                            .repeatForever(autoreverses: false)
                            .delay(Double(i) * 0.7),
                        value: pulse
                    )
            }
            Circle()
                .fill(Tint.blue.opacity(0.12))
                .frame(width: 44, height: 44)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Tint.blue)
        }
        .frame(width: 56, height: 56)
        .onAppear { pulse = true }
    }
}

// MARK: - File Row with hover-to-reveal actions

struct FileRow: View {
    let fileURL: URL
    @Binding var isSelected: Bool
    let fileSize: Int64?
    let onRemove: () -> Void

    @State private var isHovering = false
    @State private var showConfirmation = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                    .resizable()
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent)
                        .lineLimit(1)
                    Text(fileURL.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Buttons stay in the layout permanently and fade with
                // hover, so the trailing size badge never jumps sideways.
                Button {
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                Button {
                    showConfirmation = true
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Remove this file")
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (isHovering ? 1 : 0.8))
                .allowsHitTesting(isHovering)

                if let size = fileSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(AnimatedCheckboxStyle())
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        )
        .scaleEffect(isHovering && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : MotionTokens.snappy, value: isHovering)
        .onHover { isHovering = $0 }
        .alert(
            Text(
                String(format: String(localized: "Remove %@?"), fileURL.lastPathComponent)
            ),
            isPresented: $showConfirmation
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { onRemove() }
        } message: {
            Text("This will permanently delete this file. This action cannot be undone.")
        }
    }
}
