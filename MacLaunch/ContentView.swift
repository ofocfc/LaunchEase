//
//  ContentView.swift
//  MacLaunch
//
//  Created by 随便 on 2026/8/14.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenDockMetrics: NSObject, ObservableObject {
    @Published private(set) var bottomInset: CGFloat = 0
    private var pendingRefreshes: [DispatchWorkItem] = []

    override init() {
        super.init()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenMetricsDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenMetricsDidChange(_:)),
            name: Notification.Name("com.apple.dock.prefchanged"),
            object: nil
        )
    }

    deinit {
        pendingRefreshes.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenMetricsDidChange(_ notification: Notification) {
        refresh()
        scheduleFollowUpRefreshes()
    }

    private func scheduleFollowUpRefreshes() {
        pendingRefreshes.forEach { $0.cancel() }
        pendingRefreshes = [0.12, 0.35].map { delay in
            let workItem = DispatchWorkItem { [weak self] in
                self?.refresh()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            return workItem
        }
    }

    func refresh() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            bottomInset = 0
            return
        }

        bottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
    }
}

struct InstalledApp: Identifiable {
    let name: String
    let url: URL
    let icon: NSImage

    var id: String {
        url.standardizedFileURL.path
    }
}

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoading = false
    private var scanFolders: [URL]

    init(folders: [URL]) {
        scanFolders = folders
        reload()
    }

    func reload(folders: [URL]? = nil) {
        if let folders {
            scanFolders = folders
        }
        isLoading = true

        var discoveredApps: [InstalledApp] = []
        var discoveredPaths = Set<String>()

        for url in Self.applicationURLs(in: scanFolders) {
            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            let path = resolvedURL.path
            guard discoveredPaths.insert(path).inserted else {
                continue
            }

            let bundle = Bundle(url: resolvedURL)
            let name = Self.localizedApplicationName(for: resolvedURL, bundle: bundle)

            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 256, height: 256)

            discoveredApps.append(
                InstalledApp(name: name, url: resolvedURL, icon: icon)
            )
        }

        apps = discoveredApps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        isLoading = false
    }

    private static func applicationURLs(in folders: [URL]) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey
        ]
        var pendingFolders = folders
        var visitedFolders = Set<String>()
        var applications: [URL] = []

        while let folder = pendingFolders.popLast() {
            let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL
            guard visitedFolders.insert(resolvedFolder.path).inserted,
                  FileManager.default.fileExists(atPath: resolvedFolder.path),
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: resolvedFolder,
                    // Asking Foundation to prefetch package keys drops some
                    // application symlinks. Also do not use .skipsHiddenFiles:
                    // macOS marks the public Safari link as hidden.
                    includingPropertiesForKeys: nil,
                    options: []
                  )
            else {
                continue
            }

            for child in children {
                guard !child.lastPathComponent.hasPrefix(".") else { continue }

                // Check the visible entry name before asking for resource values. This
                // keeps application symlinks (Safari is one) from being skipped.
                if child.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    let resolvedApplication = child.resolvingSymlinksInPath()
                    if FileManager.default.fileExists(atPath: resolvedApplication.path) {
                        applications.append(resolvedApplication)
                    }
                    continue
                }

                guard let values = try? child.resourceValues(forKeys: resourceKeys),
                      values.isDirectory == true,
                      values.isPackage != true
                else {
                    continue
                }

                pendingFolders.append(child)
            }
        }

        return applications
    }

    private static func localizedApplicationName(for url: URL, bundle: Bundle?) -> String {
        if let bundle {
            if let loctableURL = bundle.url(
                forResource: "InfoPlist",
                withExtension: "loctable"
            ),
            let loctableData = try? Data(contentsOf: loctableURL),
            let propertyList = try? PropertyListSerialization.propertyList(
                from: loctableData,
                options: [],
                format: nil
            ),
            let localizedTables = propertyList as? [String: Any] {
                let availableLocalizations = Array(localizedTables.keys)

                for localization in preferredLocalizations(from: availableLocalizations) {
                    guard let localizedInfo = localizedTables[localization] as? [String: Any]
                    else {
                        continue
                    }

                    if let name = applicationName(in: localizedInfo) {
                        return name
                    }
                }
            }

            let preferredLocalizations = Bundle.preferredLocalizations(
                from: bundle.localizations,
                forPreferences: Locale.preferredLanguages
            )

            for localization in preferredLocalizations {
                guard let stringsURL = bundle.url(
                    forResource: "InfoPlist",
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localization
                ),
                let stringsData = try? Data(contentsOf: stringsURL),
                let propertyList = try? PropertyListSerialization.propertyList(
                    from: stringsData,
                    options: [],
                    format: nil
                ),
                let localizedInfo = propertyList as? [String: Any]
                else {
                    continue
                }

                if let name = applicationName(in: localizedInfo) {
                    return name
                }
            }
        }

        let fileManagerName = FileManager.default.displayName(atPath: url.path)
        if !fileManagerName.isEmpty {
            return (fileManagerName as NSString).deletingPathExtension
        }

        return bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private static func applicationName(in localizedInfo: [String: Any]) -> String? {
        if let displayName = localizedInfo["CFBundleDisplayName"] as? String,
           !displayName.isEmpty {
            return displayName
        }

        if let bundleName = localizedInfo["CFBundleName"] as? String,
           !bundleName.isEmpty {
            return bundleName
        }

        return nil
    }

    private static func preferredLocalizations(from availableLocalizations: [String]) -> [String] {
        var result: [String] = []

        func append(_ localization: String?) {
            guard let localization, !result.contains(localization) else { return }
            result.append(localization)
        }

        let normalizedAvailable = Dictionary(
            uniqueKeysWithValues: availableLocalizations.map {
                ($0.replacingOccurrences(of: "-", with: "_").lowercased(), $0)
            }
        )

        for preferredLanguage in Locale.preferredLanguages {
            let normalized = preferredLanguage
                .replacingOccurrences(of: "-", with: "_")
                .lowercased()
            let components = normalized.split(separator: "_").map(String.init)
            guard let language = components.first else { continue }

            append(normalizedAvailable[normalized])

            if language == "zh" {
                let isTraditional = components.contains("hant")
                    || components.contains("tw")
                    || components.contains("hk")
                    || components.contains("mo")

                if isTraditional {
                    if components.contains("hk") || components.contains("mo") {
                        append(normalizedAvailable["zh_hk"])
                    }
                    append(normalizedAvailable["zh_tw"])
                    append(normalizedAvailable["zh_hant"])
                } else {
                    append(normalizedAvailable["zh_cn"])
                    append(normalizedAvailable["zh_hans"])
                }
            }

            append(normalizedAvailable[language])

            for localization in availableLocalizations where localization
                .replacingOccurrences(of: "-", with: "_")
                .lowercased()
                .hasPrefix(language + "_") {
                append(localization)
            }
        }

        for localization in Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: Locale.preferredLanguages
        ) {
            append(localization)
        }

        append(normalizedAvailable["en"])
        availableLocalizations.forEach { append($0) }
        return result
    }

    func open(_ app: InstalledApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        // Match clicking the empty background: dismiss before asking LaunchServices
        // to open the selected app so the launcher never lingers on screen.
        LauncherWindowController.shared.hide()

        NSWorkspace.shared.openApplication(
            at: app.url,
            configuration: configuration
        ) { _, error in
            guard error != nil else { return }

            DispatchQueue.main.async {
                LauncherWindowController.shared.show()
            }
        }
    }

    func revealInFinder(_ app: InstalledApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }
}

struct ContentView: View {
    @StateObject private var settings: LauncherSettings
    @StateObject private var library: AppLibrary
    @StateObject private var layoutStore: LaunchpadLayoutStore
    @StateObject private var screenDockMetrics: ScreenDockMetrics
    @State private var searchText = ""
    @State private var hasAppeared = false
    @State private var currentPage = 0
    @State private var showsSettings = false
    @State private var openedFolderID: String?
    @State private var mainPagerFrame = CGRect.zero
    @FocusState private var isSearchFocused: Bool

    init() {
        let settings = LauncherSettings()
        let library = AppLibrary(folders: settings.applicationFolders)
        let layoutStore = LaunchpadLayoutStore()
        layoutStore.reconcile(apps: library.apps)
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: library)
        _layoutStore = StateObject(wrappedValue: layoutStore)
        _screenDockMetrics = StateObject(wrappedValue: ScreenDockMetrics())
    }

    private var filteredItems: [LaunchpadItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return layoutStore.items
        }

        return layoutStore.items.filter { item in
            if item.name.localizedCaseInsensitiveContains(query) {
                return true
            }
            return item.folder?.apps.contains {
                $0.name.localizedCaseInsensitiveContains(query)
            } == true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopWallpaperView()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissLauncher)

                VStack(spacing: 0) {
                    searchBar
                        .padding(.top, 48)
                        .padding(.bottom, 32)

                    if library.isLoading {
                        loadingView
                    } else if filteredItems.isEmpty {
                        emptyView
                    } else {
                        appGrid(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .opacity(hasAppeared ? 1 : 0)
                .scaleEffect(hasAppeared ? 1 : 0.985)
                .offset(y: hasAppeared ? 0 : 10)

                if let openedFolderID,
                   layoutStore.folder(withID: openedFolderID) != nil {
                    FolderOverlay(
                        folderID: openedFolderID,
                        layoutStore: layoutStore,
                        openAction: openAppFromFolder,
                        closeAction: closeFolder,
                        dropIndexAction: mainDropIndex
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                EscapeKeyMonitor(action: handleEscape)
                    .frame(width: 0, height: 0)
            }
        }
        .coordinateSpace(name: LaunchpadRootCoordinateSpace.name)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            screenDockMetrics.refresh()
            withAnimation(.easeOut(duration: 0.36)) {
                hasAppeared = true
            }
        }
        .onChange(of: searchText) {
            currentPage = 0
        }
        .onChange(of: settings.applicationFolderPaths) {
            currentPage = 0
            library.reload(folders: settings.applicationFolders)
        }
        .onReceive(library.$apps) { apps in
            layoutStore.reconcile(apps: apps)
            if let openedFolderID,
               layoutStore.folder(withID: openedFolderID) == nil {
                self.openedFolderID = nil
            }
        }
        .onExitCommand(perform: handleEscape)
        .onPreferenceChange(MainPagerFramePreferenceKey.self) {
            mainPagerFrame = $0
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            searchField

            Button {
                isSearchFocused = false
                showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 42, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.black.opacity(0.16))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(.white.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
            .help("启动台设置")
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                LauncherSettingsView(
                    settings: settings,
                    isPresented: $showsSettings
                )
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(.horizontal, 15)
        .frame(width: 286, height: 42)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.black.opacity(0.16))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .animation(.easeOut(duration: 0.16), value: searchText.isEmpty)
    }

    private var loadingView: some View {
        VStack(spacing: 13) {
            ProgressView()
                .controlSize(.large)
            Text("正在查找应用…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
            Text("没有找到应用")
                .font(.system(size: 16, weight: .semibold))
            Text("请尝试其他关键词")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismissLauncher)
    }

    private func appGrid(width: CGFloat, height: CGFloat) -> some View {
        let columnCount = settings.columnCount
        let rowCount = settings.rowCount
        let pageSize = columnCount * rowCount
        let pages = filteredItems.chunked(into: pageSize)
        let horizontalInset = max(56, width * 0.075)

        return CoreAnimationPager(
            pages: pages,
            columnCount: columnCount,
            rowCount: rowCount,
            horizontalInset: horizontalInset,
            selectedPage: $currentPage,
            openAction: library.open,
            revealAction: library.revealInFinder,
            openFolderAction: openFolder,
            moveAction: layoutStore.move,
            mergeAction: layoutStore.merge,
            allowsEditing: searchText.isEmpty,
            dismissAction: dismissLauncher
        )
        .background {
            GeometryReader { pagerGeometry in
                Color.clear.preference(
                    key: MainPagerFramePreferenceKey.self,
                    value: pagerGeometry.frame(
                        in: .named(LaunchpadRootCoordinateSpace.name)
                    )
                )
            }
        }
        .overlay(alignment: .bottom) {
            if pages.count > 1 {
                HStack(spacing: 9) {
                    ForEach(pages.indices, id: \.self) { page in
                        Button {
                            selectPage(page)
                        } label: {
                            Circle()
                                .fill(.white.opacity(currentPage == page ? 0.95 : 0.3))
                                .frame(width: 8, height: 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize()
                .padding(.bottom, 4)
            }
        }
        // visibleFrame ends at the Dock's nominal edge. Keep a little more room
        // for its shadow and enlarged icon edge, then let the grid redistribute
        // every row inside the remaining height.
        .padding(.bottom, max(32, screenDockMetrics.bottomInset + 44))
        .onChange(of: pages.count) {
            let lastPage = max(0, pages.count - 1)
            currentPage = min(currentPage, lastPage)
        }
    }

    private func selectPage(_ page: Int) {
        guard page != currentPage else { return }
        currentPage = page
    }

    private func mainDropIndex(at location: CGPoint) -> Int {
        guard mainPagerFrame.width > 0, mainPagerFrame.height > 0 else {
            return layoutStore.items.count
        }

        let columns = settings.columnCount
        let rows = settings.rowCount
        let pageSize = columns * rows
        let pageCount = max(1, (filteredItems.count + pageSize - 1) / pageSize)
        let horizontalInset = max(56, mainPagerFrame.width * 0.075)
        let metrics = LaunchpadGridMetrics(
            size: mainPagerFrame.size,
            columnCount: columns,
            rowCount: rows,
            horizontalInset: horizontalInset,
            showsPageIndicator: pageCount > 1
        )
        let localPoint = CGPoint(
            x: location.x - mainPagerFrame.minX,
            y: location.y - mainPagerFrame.minY
        )

        var closestSlot = 0
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for row in 0..<rows {
            for column in 0..<columns {
                let slot = row * columns + column
                let center = metrics.slotCenter(row: row, column: column)
                let candidateDistance = hypot(
                    localPoint.x - center.x,
                    localPoint.y - center.y
                )
                if candidateDistance < closestDistance {
                    closestDistance = candidateDistance
                    closestSlot = slot
                }
            }
        }

        let pageStart = min(currentPage * pageSize, filteredItems.count)
        let pageItems = Array(
            filteredItems.dropFirst(pageStart).prefix(pageSize)
        )

        if pageItems.indices.contains(closestSlot),
           let targetIndex = layoutStore.items.firstIndex(
               where: { $0.id == pageItems[closestSlot].id }
           ) {
            return targetIndex
        }

        if let lastItem = pageItems.last,
           let lastIndex = layoutStore.items.firstIndex(where: { $0.id == lastItem.id }) {
            return lastIndex + 1
        }

        return layoutStore.items.count
    }

    private func dismissLauncher() {
        isSearchFocused = false
        openedFolderID = nil
        LauncherWindowController.shared.hide()
    }

    private func openFolder(_ folderID: String) {
        isSearchFocused = false
        withAnimation(.easeOut(duration: 0.2)) {
            openedFolderID = folderID
        }
    }

    private func closeFolder() {
        withAnimation(.easeOut(duration: 0.18)) {
            openedFolderID = nil
        }
    }

    private func openAppFromFolder(_ app: InstalledApp) {
        openedFolderID = nil
        library.open(app)
    }

    private func handleEscape() {
        if openedFolderID != nil {
            closeFolder()
        } else {
            dismissLauncher()
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}

private enum LaunchpadRootCoordinateSpace {
    static let name = "launchpad-root"
}

private struct MainPagerFramePreferenceKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private struct FolderOverlay: View {
    let folderID: String
    @ObservedObject var layoutStore: LaunchpadLayoutStore
    let openAction: (InstalledApp) -> Void
    let closeAction: () -> Void
    let dropIndexAction: (CGPoint) -> Int
    @State private var draftName = ""
    @State private var draggingAppID: String?
    @State private var dragLocation = CGPoint.zero
    @State private var previewAppIDs: [String] = []
    @State private var folderItemFrames: [String: CGRect] = [:]
    @State private var folderReorderTargetID: String?
    @State private var hasExitedFolder = false

    var body: some View {
        if let folder = layoutStore.folder(withID: folderID) {
            GeometryReader { geometry in
                let metrics = folderMetrics(in: geometry.size, appCount: folder.apps.count)

                ZStack {
                    ZStack {
                        FolderVisualEffectView(
                            material: .underWindowBackground,
                            blendingMode: .withinWindow
                        )
                        .opacity(0.5)

                        Color.black.opacity(0.2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeAction)
                    .opacity(hasExitedFolder ? 0 : 1)

                    VStack(spacing: 18) {
                        TextField("文件夹名称", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.97))
                            .multilineTextAlignment(.center)
                            .frame(width: 360, height: 30)
                            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                            .onSubmit(commitName)

                        ScrollView(.vertical) {
                            LazyVGrid(columns: metrics.columns, spacing: 22) {
                                ForEach(displayedApps(in: folder)) { app in
                                    FolderAppTile(
                                        app: app,
                                        isDragging: draggingAppID == app.id,
                                        openAction: { openAction(app) },
                                        revealAction: {
                                            NSWorkspace.shared.activateFileViewerSelecting([app.url])
                                        },
                                        dragChanged: { location in
                                            updateFolderDrag(
                                                app,
                                                at: location,
                                                folder: folder,
                                                panelFrame: metrics.panelFrame
                                            )
                                        },
                                        dragEnded: { location in
                                            finishDragging(
                                                app,
                                                at: location,
                                                panelFrame: metrics.panelFrame
                                            )
                                        }
                                    )
                                    .zIndex(draggingAppID == app.id ? 2 : 0)
                                    .background {
                                        GeometryReader { itemGeometry in
                                            Color.clear.preference(
                                                key: FolderItemFramePreferenceKey.self,
                                                value: [
                                                    app.id: itemGeometry.frame(
                                                        in: .named(FolderCoordinateSpace.name)
                                                    )
                                                ]
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 32)
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                    .frame(width: metrics.panelFrame.width, height: metrics.panelFrame.height)
                    .background {
                        ZStack {
                            FolderVisualEffectView(
                                material: .hudWindow,
                                blendingMode: .withinWindow
                            )

                            LinearGradient(
                                colors: [
                                    .white.opacity(0.16),
                                    .white.opacity(0.055),
                                    .black.opacity(0.1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                        )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.38), radius: 42, y: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .position(x: metrics.panelFrame.midX, y: metrics.panelFrame.midY)
                    .onTapGesture { }
                    .opacity(hasExitedFolder ? 0 : 1)

                    if let draggingApp = folder.apps.first(where: { $0.id == draggingAppID }) {
                        FolderDragPreview(app: draggingApp)
                            .position(dragLocation)
                            .allowsHitTesting(false)
                            .zIndex(100)
                    }
                }
                .coordinateSpace(name: FolderCoordinateSpace.name)
                .onPreferenceChange(FolderItemFramePreferenceKey.self) {
                    folderItemFrames = $0
                }
            }
            .ignoresSafeArea()
            .zIndex(20)
            .onAppear {
                draftName = folder.name
                previewAppIDs = folder.apps.map(\.id)
                hasExitedFolder = false
            }
            .onChange(of: folder.name) {
                draftName = folder.name
            }
            .onChange(of: folder.apps.map(\.id)) { _, appIDs in
                guard draggingAppID == nil else { return }
                previewAppIDs = appIDs
            }
        }
    }

    private func displayedApps(in folder: LaunchpadFolder) -> [InstalledApp] {
        guard !previewAppIDs.isEmpty else { return folder.apps }
        let appsByID = Dictionary(uniqueKeysWithValues: folder.apps.map { ($0.id, $0) })
        var insertedIDs = Set<String>()
        var result = previewAppIDs.compactMap { appID -> InstalledApp? in
            guard insertedIDs.insert(appID).inserted else { return nil }
            return appsByID[appID]
        }
        result.append(contentsOf: folder.apps.filter { insertedIDs.insert($0.id).inserted })
        return result
    }

    private func updateFolderDrag(
        _ app: InstalledApp,
        at location: CGPoint,
        folder: LaunchpadFolder,
        panelFrame: CGRect
    ) {
        draggingAppID = app.id
        dragLocation = location

        if !panelFrame.contains(location) {
            guard !hasExitedFolder else { return }
            folderReorderTargetID = nil
            withAnimation(.easeOut(duration: 0.16)) {
                hasExitedFolder = true
            }
            return
        }

        guard !hasExitedFolder else { return }

        if previewAppIDs.isEmpty {
            previewAppIDs = folder.apps.map(\.id)
        }

        let candidates = folderItemFrames.filter { $0.key != app.id }
        let directTarget = candidates.first { $0.value.insetBy(dx: 10, dy: 14).contains(location) }
        let target = directTarget ?? candidates.min { first, second in
            hypot(location.x - first.value.midX, location.y - first.value.midY)
                < hypot(location.x - second.value.midX, location.y - second.value.midY)
        }
        guard let target,
              hypot(location.x - target.value.midX, location.y - target.value.midY) < 105,
              folderReorderTargetID != target.key,
              let sourceIndex = previewAppIDs.firstIndex(of: app.id),
              let targetIndex = previewAppIDs.firstIndex(of: target.key)
        else { return }

        folderReorderTargetID = target.key
        var reorderedIDs = previewAppIDs
        let sourceID = reorderedIDs.remove(at: sourceIndex)
        reorderedIDs.insert(sourceID, at: min(targetIndex, reorderedIDs.count))

        withAnimation(.easeOut(duration: 0.17)) {
            previewAppIDs = reorderedIDs
        }
    }

    private func folderMetrics(in size: CGSize, appCount: Int) -> FolderMetrics {
        let maximumColumns = min(7, max(4, Int((size.width - 150) / 150)))
        let visibleColumns = min(maximumColumns, max(4, appCount))
        let columns = Array(
            repeating: GridItem(.fixed(138), spacing: 20),
            count: visibleColumns
        )
        let contentWidth = CGFloat(visibleColumns) * 138
            + CGFloat(max(0, visibleColumns - 1)) * 20
        let panelWidth = min(size.width - 96, max(680, contentWidth + 76))
        let rows = max(1, Int(ceil(Double(appCount) / Double(visibleColumns))))
        let panelHeight = min(size.height - 132, max(276, 100 + CGFloat(rows) * 154))
        let panelFrame = CGRect(
            x: (size.width - panelWidth) / 2,
            y: (size.height - panelHeight) / 2 - 8,
            width: panelWidth,
            height: panelHeight
        )
        return FolderMetrics(columns: columns, panelFrame: panelFrame)
    }

    private func finishDragging(
        _ app: InstalledApp,
        at location: CGPoint,
        panelFrame: CGRect
    ) {
        let droppedOutside = hasExitedFolder || !panelFrame.contains(location)
        if !droppedOutside {
            layoutStore.reorderApps(inFolder: folderID, orderedAppIDs: previewAppIDs)
        }

        withAnimation(.easeOut(duration: 0.15)) {
            draggingAppID = nil
        }
        folderReorderTargetID = nil

        guard droppedOutside else { return }

        let destinationIndex = dropIndexAction(location)
        _ = layoutStore.moveApp(
            app.id,
            outOfFolder: folderID,
            to: destinationIndex
        )
        closeAction()
    }

    private func commitName() {
        layoutStore.renameFolder(folderID, to: draftName)
        draftName = layoutStore.folder(withID: folderID)?.name ?? draftName
    }
}

private struct FolderMetrics {
    let columns: [GridItem]
    let panelFrame: CGRect
}

private enum FolderCoordinateSpace {
    static let name = "launchpad-folder-overlay"
}

private struct FolderItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct FolderAppTile: View {
    let app: InstalledApp
    let isDragging: Bool
    let openAction: () -> Void
    let revealAction: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: (CGPoint) -> Void

    var body: some View {
        VStack(spacing: 11) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 94, height: 94)
                .shadow(color: .black.opacity(0.32), radius: 8, y: 5)

            Text(app.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.97))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 132, height: 34, alignment: .top)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        }
        .frame(width: 138, height: 139, alignment: .top)
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.12 : 1)
        .scaleEffect(isDragging ? 0.96 : 1)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .onTapGesture(perform: openAction)
        .gesture(
            DragGesture(
                minimumDistance: 6,
                coordinateSpace: .named(FolderCoordinateSpace.name)
            )
            .onChanged { dragChanged($0.location) }
            .onEnded { dragEnded($0.location) }
        )
        .contextMenu {
            Button("打开", action: openAction)
            Button("在 Finder 中显示", action: revealAction)
        }
        .help(app.name)
    }
}

private struct FolderDragPreview: View {
    let app: InstalledApp

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 100, height: 100)
                .shadow(color: .black.opacity(0.45), radius: 12, y: 7)

            Text(app.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 138)
                .shadow(color: .black.opacity(0.85), radius: 2, y: 1)
        }
        .scaleEffect(1.06)
    }
}

private struct FolderVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.isEmphasized = true
        update(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        update(nsView)
    }

    private func update(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
    }
}

private struct LaunchpadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private struct DesktopWallpaperView: View {
    private static let wallpaper = loadWallpaper()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let wallpaper = Self.wallpaper {
                    Image(nsImage: wallpaper)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(1.08)
                        .blur(radius: 30, opaque: true)
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.05, green: 0.12, blue: 0.1),
                            Color(red: 0.12, green: 0.2, blue: 0.08),
                            Color(red: 0.03, green: 0.06, blue: 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                Color.black.opacity(0.4)

                LinearGradient(
                    colors: [
                        .black.opacity(0.16),
                        .clear,
                        .black.opacity(0.34)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private static func loadWallpaper() -> NSImage? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var action: () -> Void
        private var monitor: Any?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func start() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, NSApplication.shared.isActive else {
                    return event
                }

                self?.action()
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}
