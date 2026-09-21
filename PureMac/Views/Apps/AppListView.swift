import SwiftUI

struct AppListView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selection: Set<InstalledApp.ID> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sortOrder: [KeyPathComparator<InstalledApp>] = [
        .init(\.appName, order: .forward)
    ]

    private var filteredApps: [InstalledApp] {
        let base: [InstalledApp]
        if searchText.isEmpty {
            base = appState.installedApps
        } else {
            let query = searchText.lowercased()
            base = appState.installedApps.filter {
                $0.appName.lowercased().contains(query) ||
                $0.bundleIdentifier.lowercased().contains(query)
            }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        HSplitView {
            // Cap the left pane's maxWidth so dragging the splitter cannot
            // push it past half the window and break the layout (#60).
            appTable
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 600)

            fileDetail
                .frame(minWidth: 300)
        }
        .searchable(text: $searchText, prompt: "Search apps")
        .navigationTitle(installedAppsTitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.loadInstalledApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                // ToolbarItems can't run insertion transitions on macOS 13 —
                // keep the button mounted and fade it with the selection.
                Button(uninstallLabel(count: appState.selectedFiles.count), role: .destructive) {
                    appState.removeSelectedFiles()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .opacity(appState.selectedFiles.isEmpty ? 0 : 1)
                .disabled(appState.selectedFiles.isEmpty)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8),
                           value: appState.selectedFiles.isEmpty)
            }
        }
    }

    private var installedAppsTitle: String {
        String(format: String(localized: "Installed Apps (%lld)"), Int64(appState.installedApps.count))
    }

    private func uninstallLabel(count: Int) -> String {
        String(format: String(localized: "Uninstall (%lld files)"), Int64(count))
    }

    // MARK: - App Table (left side)

    private var appTable: some View {
        Group {
            if appState.isLoadingApps {
                VStack(spacing: 12) {
                    ProgressView(LocalizedStringKey("Loading installed apps..."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.installedApps.isEmpty {
                EmptyStateView(
                    "No Apps Found",
                    systemImage: "square.grid.2x2",
                    description: "Could not find any installed applications.",
                    action: { appState.loadInstalledApps() },
                    actionLabel: "Retry"
                )
            } else {
                Table(filteredApps, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Application", value: \.appName) { app in
                        HStack(spacing: 8) {
                            HoverScaleIcon(icon: app.icon)
                            Text(app.appName)
                        }
                    }
                    .width(min: 150)

                    TableColumn("Size", value: \.size) { app in
                        Text(app.formattedSize)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .width(ideal: 70)
                }
                .onChange(of: selection) { newSelection in
                    let selectedApps = appState.installedApps.filter { newSelection.contains($0.id) }
                    appState.selectApps(selectedApps)
                }
                .onChange(of: appState.selectedAppBundleIDs) { newBundleIDs in
                    let mappedIDs = Set(appState.installedApps.filter { newBundleIDs.contains($0.bundleIdentifier) }.map(\.id))
                    if selection != mappedIDs { selection = mappedIDs }
                }
                .onChange(of: appState.installedApps) { apps in
                    // Refresh produces new UUIDs: remap highlight from stable bundleIDs
                    let mappedIDs = Set(apps.filter { appState.selectedAppBundleIDs.contains($0.bundleIdentifier) }.map(\.id))
                    if selection != mappedIDs { selection = mappedIDs }
                }
                .onAppear {
                    // Sync the highlight when this view mounts already pointed
                    // at externally-selected apps.
                    let mappedIDs = Set(appState.installedApps.filter { appState.selectedAppBundleIDs.contains($0.bundleIdentifier) }.map(\.id))
                    if selection != mappedIDs {
                        selection = mappedIDs
                    }
                }
            }
        }
    }

    // MARK: - File Detail (right side)

    @ViewBuilder
    private var fileDetail: some View {
        if !appState.selectedAppBundleIDs.isEmpty {
            AppFilesView()
        } else {
            EmptyStateView(
                "Select an App",
                systemImage: "cursorarrow.click.2",
                description: "Select one or more apps from the list to see related files across your system.",
                tint: Tint.purple
            )
        }
    }
}

/// App icon that scales up slightly on hover inside a Table cell.
private struct HoverScaleIcon: View {
    let icon: NSImage

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: 22, height: 22)
            .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
            .animation(reduceMotion ? nil : MotionTokens.snappy, value: hovering)
            .onHover { hovering = $0 }
    }
}
