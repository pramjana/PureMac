import AppKit
import XCTest
@testable import PureMac

@MainActor
final class AppStateMultiUninstallTests: XCTestCase {
    func testSelectingMultipleAppsScansThemSequentially() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        // Intentionally provide out-of-order to verify name-based sorting in scan queue
        state.selectApps([appB, appA])

        XCTAssertTrue(state.isScanningAppFiles)
        XCTAssertEqual(scanCalls.count, 1)
        XCTAssertEqual(scanCalls.first?.bundleIdentifier, "com.test.appa")
        XCTAssertEqual(state.currentlyScanningBundleID, "com.test.appa")

        let urlsA: Set<URL> = [
            URL(fileURLWithPath: "/tmp/a_cache"),
            URL(fileURLWithPath: "/tmp/a_support")
        ]
        pendingCompletions[0](urlsA)

        XCTAssertTrue(state.isScanningAppFiles)
        XCTAssertEqual(scanCalls.count, 2)
        XCTAssertEqual(scanCalls[1].bundleIdentifier, "com.test.appb")
        XCTAssertEqual(state.currentlyScanningBundleID, "com.test.appb")
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], urlsA.sorted { $0.path < $1.path })

        let urlsB: Set<URL> = [
            URL(fileURLWithPath: "/tmp/b_cache")
        ]
        pendingCompletions[1](urlsB)

        XCTAssertFalse(state.isScanningAppFiles)
        XCTAssertNil(state.currentlyScanningBundleID)
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], Array(urlsB))
        let expectedUnion = (urlsA.union(urlsB)).sorted { $0.path < $1.path }
        XCTAssertEqual(state.discoveredFiles, expectedUnion)
        XCTAssertEqual(state.selectedFiles, urlsA.union(urlsB))
    }

    func testAlreadyScannedAppIsNotRescannedWhenStillSelected() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA])
        XCTAssertEqual(scanCalls.count, 1)
        pendingCompletions[0]([URL(fileURLWithPath: "/tmp/a")])

        // Add appB while appA is already scanned and still selected
        state.selectApps([appA, appB])
        XCTAssertEqual(scanCalls.count, 2)
        XCTAssertEqual(scanCalls[1].bundleIdentifier, "com.test.appb")
    }

    func testReselectingDeselectedAppRescansIt() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA])
        XCTAssertEqual(scanCalls.count, 1)
        pendingCompletions[0]([URL(fileURLWithPath: "/tmp/a")])

        // Deselect appA by selecting only appB
        state.selectApps([appB])
        XCTAssertEqual(scanCalls.count, 2)
        XCTAssertEqual(scanCalls[1].bundleIdentifier, "com.test.appb")
        pendingCompletions[1]([URL(fileURLWithPath: "/tmp/b")])

        // Re-select appA alongside appB
        state.selectApps([appA, appB])
        XCTAssertEqual(scanCalls.count, 3)
        XCTAssertEqual(scanCalls[2].bundleIdentifier, "com.test.appa")
    }

    func testScanningProgressAndFlags() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            locationsProvider: { StubLocations(paths: ["/p1", "/p2", "/p3"]) },
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA, appB])

        XCTAssertTrue(state.isScanningAppFiles)
        XCTAssertEqual(state.scansTotal, 2)
        XCTAssertEqual(state.scansCompleted, 0)
        XCTAssertEqual(state.appFileScanLocationCount, 3)

        pendingCompletions[0]([URL(fileURLWithPath: "/tmp/a")])

        XCTAssertTrue(state.isScanningAppFiles)
        XCTAssertEqual(state.scansTotal, 2)
        XCTAssertEqual(state.scansCompleted, 1)

        pendingCompletions[1]([URL(fileURLWithPath: "/tmp/b")])

        XCTAssertFalse(state.isScanningAppFiles)
        XCTAssertEqual(state.scansTotal, 2)
        XCTAssertEqual(state.scansCompleted, 2)
        XCTAssertEqual(state.appFileScanLocationCount, 0)
    }

    func testDeselectingAppRemovesItsFilesFromPaneAndSelection() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA, appB])

        let urlsA: Set<URL> = [URL(fileURLWithPath: "/tmp/a_file")]
        let urlsB: Set<URL> = [URL(fileURLWithPath: "/tmp/b_file")]

        pendingCompletions[0](urlsA)
        pendingCompletions[1](urlsB)

        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], Array(urlsA))
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], Array(urlsB))
        XCTAssertTrue(state.selectedFiles.contains(urlsA.first!))
        XCTAssertTrue(state.selectedFiles.contains(urlsB.first!))

        // Deselect AppB by passing only [appA]
        state.selectApps([appA])

        XCTAssertNil(state.discoveredFilesByApp["com.test.appb"])
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], Array(urlsA))
        XCTAssertEqual(state.discoveredFiles, Array(urlsA))
        XCTAssertFalse(state.selectedFiles.contains(urlsB.first!))
        XCTAssertTrue(state.selectedFiles.contains(urlsA.first!))
        XCTAssertFalse(state.selectedAppBundleIDs.contains("com.test.appb"))
    }

    func testStaleCompletionForDeselectedAppIsDiscarded() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        state.selectApps([appA])
        XCTAssertEqual(scanCalls.count, 1)

        // Deselect appA before completion fires
        state.selectApps([])

        // Stale completion arrives for appA
        let urlsA: Set<URL> = [URL(fileURLWithPath: "/tmp/a_file")]
        pendingCompletions[0](urlsA)

        XCTAssertNil(state.discoveredFilesByApp["com.test.appa"])
        XCTAssertTrue(state.discoveredFiles.isEmpty)
        XCTAssertTrue(state.selectedFiles.isEmpty)
    }

    func testForceRescanReplacesOnlyThatAppsEntry() {
        var scanCalls: [InstalledApp] = []
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { app, _, completion in
                scanCalls.append(app)
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA, appB])
        pendingCompletions[0]([URL(fileURLWithPath: "/tmp/a_old")])
        pendingCompletions[1]([URL(fileURLWithPath: "/tmp/b_file")])

        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], [URL(fileURLWithPath: "/tmp/a_old")])
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [URL(fileURLWithPath: "/tmp/b_file")])

        // Force rescan appA
        state.scanForAppFiles(appA)
        XCTAssertEqual(scanCalls.count, 3)

        // Before completion of rescan, appA's discovered files is empty and old files removed from selectedFiles
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], [])
        XCTAssertFalse(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/a_old")))
        // But appB remains completely intact
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [URL(fileURLWithPath: "/tmp/b_file")])
        XCTAssertTrue(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/b_file")))

        // Complete rescan for appA with new files
        pendingCompletions[2]([URL(fileURLWithPath: "/tmp/a_new")])

        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], [URL(fileURLWithPath: "/tmp/a_new")])
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [URL(fileURLWithPath: "/tmp/b_file")])
        XCTAssertTrue(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/a_new")))
        XCTAssertTrue(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/b_file")))
    }

    func testSharedFileAttributedToFirstScannedApp() {
        var pendingCompletions: [(Set<URL>) -> Void] = []

        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, completion in
                pendingCompletions.append(completion)
            }
        )

        let appA = makeApp(name: "AppA", bundleID: "com.test.appa")
        let appB = makeApp(name: "AppB", bundleID: "com.test.appb")

        state.selectApps([appA, appB])

        let sharedURL = URL(fileURLWithPath: "/Library/Caches/shared.cache")
        let uniqueA = URL(fileURLWithPath: "/tmp/a_unique")
        let uniqueB = URL(fileURLWithPath: "/tmp/b_unique")

        pendingCompletions[0]([uniqueA, sharedURL])
        pendingCompletions[1]([uniqueB, sharedURL])

        // First-scanned appA owns the shared file
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], [sharedURL, uniqueA].sorted { $0.path < $1.path })
        // appB does NOT own the shared file
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [uniqueB])

        // Union contains sharedURL exactly once
        let expectedUnion = [sharedURL, uniqueA, uniqueB].sorted { $0.path < $1.path }
        XCTAssertEqual(state.discoveredFiles, expectedUnion)
        XCTAssertEqual(state.discoveredFiles.filter { $0 == sharedURL }.count, 1)
        XCTAssertEqual(state.selectedFiles, Set(expectedUnion))
    }

    func testRemovingFilesAcrossAppsUpdatesAllSections() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pathA = tempDir.appendingPathComponent("AppA.app")
        let pathB = tempDir.appendingPathComponent("AppB.app")
        try FileManager.default.createDirectory(at: pathA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: true)

        var trasherCalledWith: [URL]?
        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, completion in
                completion([])
            },
            appFileTrasher: { urls, completion in
                trasherCalledWith = urls
                completion(urls, false, [], [])
            }
        )

        let appA = InstalledApp(
            id: UUID(),
            appName: "AppA",
            bundleIdentifier: "com.test.appa",
            path: pathA,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 100
        )
        let appB = InstalledApp(
            id: UUID(),
            appName: "AppB",
            bundleIdentifier: "com.test.appb",
            path: pathB,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 100
        )

        state.installedApps = [appA, appB]
        state.selectApps([appA, appB])

        let urlA1 = URL(fileURLWithPath: "/tmp/a1")
        let urlA2 = URL(fileURLWithPath: "/tmp/a2")
        let urlB1 = URL(fileURLWithPath: "/tmp/b1")
        let urlB2 = URL(fileURLWithPath: "/tmp/b2")

        state.discoveredFilesByApp["com.test.appa"] = [urlA1, urlA2]
        state.discoveredFilesByApp["com.test.appb"] = [urlB1, urlB2]
        state.selectedFiles = [urlA1, urlA2, urlB1, urlB2]

        // Remove a1 and b1
        let toRemove: Set<URL> = [urlA1, urlB1]
        state.removeSelectedFiles(confirmedURLs: toRemove)

        XCTAssertEqual(Set(trasherCalledWith ?? []), toRemove)
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appa"], [urlA2])
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [urlB2])
        XCTAssertEqual(state.selectedFiles, [urlA2, urlB2])
        XCTAssertEqual(state.discoveredFiles, [urlA2, urlB2].sorted { $0.path < $1.path })
    }

    func testPruningUninstalledAppDropsItFromSelection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pathA = tempDir.appendingPathComponent("AppA.app")
        let pathB = tempDir.appendingPathComponent("AppB.app")
        try FileManager.default.createDirectory(at: pathA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: true)

        let state = AppState(performStartupTasks: false)

        let appA = InstalledApp(
            id: UUID(),
            appName: "AppA",
            bundleIdentifier: "com.test.appa",
            path: pathA,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 100
        )
        let appB = InstalledApp(
            id: UUID(),
            appName: "AppB",
            bundleIdentifier: "com.test.appb",
            path: pathB,
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: 100
        )

        state.installedApps = [appA, appB]
        state.selectApps([appA, appB])
        state.discoveredFilesByApp["com.test.appa"] = [URL(fileURLWithPath: "/tmp/a_leftover")]
        state.discoveredFilesByApp["com.test.appb"] = [URL(fileURLWithPath: "/tmp/b_leftover")]
        state.selectedFiles = [URL(fileURLWithPath: "/tmp/a_leftover"), URL(fileURLWithPath: "/tmp/b_leftover")]

        // Remove AppA from disk
        try FileManager.default.removeItem(at: pathA)

        state.pruneMissingInstalledApps()

        XCTAssertFalse(state.selectedAppBundleIDs.contains("com.test.appa"))
        XCTAssertNil(state.discoveredFilesByApp["com.test.appa"])
        XCTAssertFalse(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/a_leftover")))

        XCTAssertTrue(state.selectedAppBundleIDs.contains("com.test.appb"))
        XCTAssertEqual(state.discoveredFilesByApp["com.test.appb"], [URL(fileURLWithPath: "/tmp/b_leftover")])
        XCTAssertTrue(state.selectedFiles.contains(URL(fileURLWithPath: "/tmp/b_leftover")))
        XCTAssertEqual(state.installedApps.map(\.bundleIdentifier), ["com.test.appb"])
    }

    func testFailedRemovalSnapshotCapturesOwningAppNames() {
        let state = AppState(
            performStartupTasks: false,
            appFileScanner: { _, _, completion in completion([]) },
            appFileTrasher: { urls, completion in
                completion([], true, [], urls)
            }
        )

        let appA = makeApp(name: "App A", bundleID: "com.test.appa")
        let appB = makeApp(name: "App B", bundleID: "com.test.appb")

        state.selectApps([appA, appB])

        let urlA = URL(fileURLWithPath: "/tmp/a1")
        let urlB = URL(fileURLWithPath: "/tmp/b1")

        state.discoveredFilesByApp["com.test.appa"] = [urlA]
        state.discoveredFilesByApp["com.test.appb"] = [urlB]
        state.selectedFiles = [urlA, urlB]

        state.removeSelectedFiles()

        XCTAssertTrue(state.removalNeedsFullDiskAccess)
        XCTAssertEqual(Set(state.lastFailedRemovalURLs), [urlA, urlB])
        XCTAssertEqual(state.lastFailedRemovalAppNames, ["App A", "App B"])
    }

    func testPermissionCoordinatorHeadlineFormatting() {
        let single = PermissionCoordinator.PromptContext.uninstall(appNames: ["App A"], failedCount: 2)
        XCTAssertEqual(single.headline, "Uninstalling App A: 2 file(s) need Full Disk Access")

        let multiple = PermissionCoordinator.PromptContext.uninstall(appNames: ["App A", "App B"], failedCount: 5)
        XCTAssertEqual(multiple.headline, "Uninstalling 2 apps: 5 file(s) need Full Disk Access")
    }

    // MARK: - Helpers

    private func makeApp(name: String, bundleID: String, size: Int64 = 1) -> InstalledApp {
        InstalledApp(
            id: UUID(),
            appName: name,
            bundleIdentifier: bundleID,
            path: URL(fileURLWithPath: "/Applications/\(name).app"),
            icon: NSImage(size: NSSize(width: 32, height: 32)),
            size: size
        )
    }
}

private final class StubLocations: Locations {
    init(paths: [String]) {
        super.init()
        appSearch = SearchCategory(name: "Apps", paths: paths)
    }
}
