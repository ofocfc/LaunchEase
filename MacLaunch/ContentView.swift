//
//  ContentView.swift
//  LaunchEase
//
//  Created by 随便 on 2026/8/14.
//

import AppKit
import Combine
import Darwin
import SwiftUI

@MainActor
final class ScreenDockMetrics: NSObject, ObservableObject {
    @Published private(set) var bottomInset: CGFloat = 0
    @Published private(set) var leftInset: CGFloat = 0
    @Published private(set) var rightInset: CGFloat = 0
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenMetricsDidChange(_:)),
            name: .launcherScreenDidChange,
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
        guard let screen = LauncherWindowController.shared.activeScreen
            ?? NSScreen.screenContainingMouse
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else {
            bottomInset = 0
            leftInset = 0
            rightInset = 0
            return
        }

        bottomInset = max(0, screen.visibleFrame.minY - screen.frame.minY)
        leftInset = max(0, screen.visibleFrame.minX - screen.frame.minX)
        rightInset = max(0, screen.frame.maxX - screen.visibleFrame.maxX)
    }
}

private enum LauncherFocusedControl: Hashable {
    case search
    case settings
}

struct InstalledApp: Identifiable {
    let name: String
    let url: URL
    let icon: NSImage

    var id: String {
        url.standardizedFileURL.path
    }
}

private struct ScannedApplicationDescriptor: Sendable {
    let url: URL
    let name: String
    let iconCacheKey: String
}

private final class ApplicationFolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.launch.MacLaunch.application-folder-watcher",
        qos: .utility
    )
    private var sources: [DispatchSourceFileSystemObject] = []

    func watch(
        _ folders: [URL],
        changeHandler: @escaping @Sendable () -> Void
    ) {
        stop()

        var watchedPaths = Set<String>()
        for folder in folders {
            let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
            guard watchedPaths.insert(path).inserted else { continue }

            let descriptor = Darwin.open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .link, .revoke],
                queue: queue
            )
            source.setEventHandler(handler: changeHandler)
            source.setCancelHandler {
                Darwin.close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    func stop() {
        let activeSources = sources
        sources.removeAll()
        activeSources.forEach { $0.cancel() }
    }

    deinit {
        stop()
    }
}

@MainActor
final class AppLibrary: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoading = false
    private var scanFolders: [URL]
    private let iconCache = NSCache<NSString, NSImage>()
    private let folderWatcher = ApplicationFolderWatcher()
    private var reloadTask: Task<Void, Never>?
    private var watcherReloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    init(folders: [URL]) {
        scanFolders = folders
        iconCache.countLimit = 512
        configureFolderWatcher()
        reload()
    }

    deinit {
        reloadTask?.cancel()
        watcherReloadTask?.cancel()
    }

    func reload(folders: [URL]? = nil) {
        if let folders {
            scanFolders = folders
            configureFolderWatcher()
        }
        reloadTask?.cancel()
        reloadGeneration += 1
        let generation = reloadGeneration
        let foldersToScan = scanFolders

        // Keep the current page visible during a refresh. Only the first scan
        // needs the full-page loading state.
        if apps.isEmpty {
            isLoading = true
        }

        reloadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let descriptors = Self.scanApplicationDescriptors(in: foldersToScan)
            guard !Task.isCancelled else { return }
            await self?.apply(descriptors, generation: generation)
        }
    }

    private func configureFolderWatcher() {
        folderWatcher.watch(scanFolders) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleWatchedFolderReload()
            }
        }
    }

    private func scheduleWatchedFolderReload() {
        watcherReloadTask?.cancel()
        watcherReloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }

            // Directory replacement or rename invalidates its vnode source.
            // Rebuild the watchers before rescanning so subsequent changes are
            // still observed.
            self.configureFolderWatcher()
            self.reload()
        }
    }

    private func apply(
        _ descriptors: [ScannedApplicationDescriptor],
        generation: Int
    ) async {
        var discoveredApps: [InstalledApp] = []
        discoveredApps.reserveCapacity(descriptors.count)

        for (index, descriptor) in descriptors.enumerated() {
            guard !Task.isCancelled,
                  generation == reloadGeneration
            else { return }

            let cacheKey = descriptor.iconCacheKey as NSString
            let icon: NSImage
            if let cachedIcon = iconCache.object(forKey: cacheKey) {
                icon = cachedIcon
            } else {
                icon = NSWorkspace.shared.icon(forFile: descriptor.url.path)
                icon.size = NSSize(width: 256, height: 256)
                iconCache.setObject(icon, forKey: cacheKey)
            }

            discoveredApps.append(
                InstalledApp(
                    name: descriptor.name,
                    url: descriptor.url,
                    icon: icon
                )
            )

            // Icon creation is AppKit work and stays on the main actor, but
            // yielding in small batches keeps animation and input responsive.
            if index.isMultiple(of: 8) {
                await Task.yield()
            }
        }

        guard generation == reloadGeneration else { return }
        apps = discoveredApps.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        isLoading = false
    }

    nonisolated private static func scanApplicationDescriptors(
        in folders: [URL]
    ) -> [ScannedApplicationDescriptor] {
        var descriptors: [ScannedApplicationDescriptor] = []
        var discoveredPaths = Set<String>()

        for url in applicationURLs(in: folders) {
            guard !Task.isCancelled else { return [] }

            let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
            let path = resolvedURL.path
            guard discoveredPaths.insert(path).inserted else { continue }

            let bundle = Bundle(url: resolvedURL)
            let name = localizedApplicationName(for: resolvedURL, bundle: bundle)
            let modificationDate = (
                try? resolvedURL.resourceValues(forKeys: [.contentModificationDateKey])
            )?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0

            descriptors.append(
                ScannedApplicationDescriptor(
                    url: resolvedURL,
                    name: name,
                    iconCacheKey: "\(path)|\(modificationDate)"
                )
            )
        }

        return descriptors
    }

    nonisolated private static func applicationURLs(in folders: [URL]) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey
        ]
        var pendingFolders = folders
        var visitedFolders = Set<String>()
        var applications: [URL] = []

        while let folder = pendingFolders.popLast() {
            guard !Task.isCancelled else { return [] }
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

    nonisolated private static func localizedApplicationName(
        for url: URL,
        bundle: Bundle?
    ) -> String {
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

    nonisolated private static func applicationName(
        in localizedInfo: [String: Any]
    ) -> String? {
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

    nonisolated private static func preferredLocalizations(
        from availableLocalizations: [String]
    ) -> [String] {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @StateObject private var settings: LauncherSettings
    @StateObject private var library: AppLibrary
    @StateObject private var layoutStore: LaunchpadLayoutStore
    @StateObject private var screenDockMetrics: ScreenDockMetrics
    @State private var searchText = ""
    @State private var hasAppeared = false
    @State private var currentPage = 0
    @State private var showsSettings = false
    @State private var openedFolderID: String?
    @State private var openedFolderOrigin: CGPoint?
    @State private var isFolderPresented = false
    @State private var mainPagerFrame = CGRect.zero
    @State private var keyboardSelectedItemID: String?
    @State private var keyboardActivationRequest = 0
    @FocusState private var focusedControl: LauncherFocusedControl?

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

        var results: [LaunchpadItem] = []
        var insertedIDs = Set<String>()
        for item in layoutStore.items {
            if let app = item.app {
                if matchesSearch(app.name, query: query),
                   insertedIDs.insert(app.id).inserted {
                    results.append(LaunchpadItem(content: .app(app)))
                }
                continue
            }

            guard let folder = item.folder else { continue }
            if matchesSearch(folder.name, query: query) {
                if insertedIDs.insert(folder.id).inserted {
                    results.append(item)
                }
                continue
            }

            for app in folder.apps where matchesSearch(app.name, query: query) {
                if insertedIDs.insert(app.id).inserted {
                    results.append(LaunchpadItem(content: .app(app)))
                }
            }
        }
        return results
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopWallpaperView()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissLauncher)
                    .accessibilityHidden(true)

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
                .opacity(hasAppeared || reduceMotion ? 1 : 0)
                .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.985)
                .offset(y: hasAppeared || reduceMotion ? 0 : 10)

                if let openedFolderID,
                   layoutStore.folder(withID: openedFolderID) != nil {
                    FolderOverlay(
                        folderID: openedFolderID,
                        sourceOrigin: openedFolderOrigin,
                        isPresented: isFolderPresented,
                        layoutStore: layoutStore,
                        openAction: openAppFromFolder,
                        closeAction: closeFolder,
                        dropIndexAction: mainDropIndex
                    )
                    .transition(.opacity)
                }

                EscapeKeyMonitor(action: handleEscape)
                    .frame(width: 0, height: 0)

                LauncherKeyboardMonitor(action: handleKeyboardEvent)
                    .frame(width: 0, height: 0)
            }
        }
        .coordinateSpace(name: LaunchpadRootCoordinateSpace.name)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            screenDockMetrics.refresh()
            withAnimation(
                reduceMotion ? nil : .spring(
                    response: LaunchpadMotion.folderResponse,
                    dampingFraction: LaunchpadMotion.folderDamping
                )
            ) {
                hasAppeared = true
            }
        }
        .onChange(of: searchText) {
            currentPage = 0
            keyboardSelectedItemID = nil
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
        .onChange(of: layoutStore.items.map(\.id)) {
            guard let openedFolderID,
                  layoutStore.folder(withID: openedFolderID) == nil
            else { return }
            self.openedFolderID = nil
            openedFolderOrigin = nil
            isFolderPresented = false
        }
        .onChange(of: currentPage) {
            keepKeyboardSelectionOnCurrentPage()
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
                focusedControl = nil
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
                    .stroke(
                        .white.opacity(colorSchemeContrast == .increased ? 0.72 : 0.2),
                        lineWidth: colorSchemeContrast == .increased ? 2 : 1
                    )
            }
            .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
            .help("启动台设置")
            .accessibilityLabel("启动台设置")
            .accessibilityHint("打开扫描目录、图标布局和备份设置")
            .focused($focusedControl, equals: .settings)
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                LauncherSettingsView(
                    settings: settings,
                    layoutStore: layoutStore,
                    isPresented: $showsSettings,
                    importAction: restoreBackup
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
                .focused($focusedControl, equals: .search)
                .accessibilityLabel("搜索应用")
                .accessibilityHint("可输入应用名称、拼音或拼音首字母")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    focusedControl = .search
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale))
                .accessibilityLabel("清除搜索内容")
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
                .stroke(
                    .white.opacity(colorSchemeContrast == .increased ? 0.72 : 0.2),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
        .animation(
            reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.quick),
            value: searchText.isEmpty
        )
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在查找应用")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("没有找到应用，请尝试其他关键词")
    }

    private func appGrid(width: CGFloat, height: CGFloat) -> some View {
        let columnCount = settings.columnCount
        let rowCount = settings.rowCount
        let pageSize = columnCount * rowCount
        let pages = filteredItems.chunked(into: pageSize)
        let usableWidth = max(
            1,
            width - screenDockMetrics.leftInset - screenDockMetrics.rightInset
        )
        let horizontalInset = max(56, usableWidth * 0.075)
        let showsPageIndicator = !isSearching && pages.count > 1

        return CoreAnimationPager(
            pages: pages,
            columnCount: columnCount,
            rowCount: rowCount,
            horizontalInset: horizontalInset,
            centersContent: isSearching,
            showsPageIndicator: showsPageIndicator,
            reduceMotion: reduceMotion,
            increasedContrast: colorSchemeContrast == .increased,
            selectedPage: $currentPage,
            keyboardSelectedItemID: $keyboardSelectedItemID,
            keyboardActivationRequest: keyboardActivationRequest,
            openAction: library.open,
            revealAction: library.revealInFinder,
            openFolderAction: openFolder,
            moveAction: layoutStore.move,
            moveToIndexAction: layoutStore.move,
            mergeAction: layoutStore.merge,
            allowsEditing: !isSearching,
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
            if showsPageIndicator {
                HStack(spacing: 9) {
                    ForEach(pages.indices, id: \.self) { page in
                        Button {
                            selectPage(page)
                        } label: {
                            Circle()
                                .fill(.white.opacity(currentPage == page ? 0.95 : 0.3))
                                .frame(
                                    width: currentPage == page && differentiateWithoutColor ? 10 : 8,
                                    height: currentPage == page && differentiateWithoutColor ? 10 : 8
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(page + 1) 页")
                        .accessibilityValue(currentPage == page ? "当前页" : "")
                        .accessibilityHint("显示这一页的应用")
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
        .padding(.leading, screenDockMetrics.leftInset)
        .padding(.trailing, screenDockMetrics.rightInset)
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
        focusedControl = nil
        keyboardSelectedItemID = nil
        openedFolderID = nil
        openedFolderOrigin = nil
        isFolderPresented = false
        LauncherWindowController.shared.hide()
    }

    private func openFolder(_ folderID: String, origin: CGPoint) {
        focusedControl = nil
        openedFolderOrigin = origin
        isFolderPresented = false
        openedFolderID = folderID
        DispatchQueue.main.async {
            guard openedFolderID == folderID else { return }
            withAnimation(
                reduceMotion ? nil : .spring(
                    response: LaunchpadMotion.folderResponse,
                    dampingFraction: LaunchpadMotion.folderDamping
                )
            ) {
                isFolderPresented = true
            }
        }
    }

    private func closeFolder() {
        guard let closingFolderID = openedFolderID else { return }
        withAnimation(
            reduceMotion ? nil : .spring(
                response: LaunchpadMotion.folderResponse,
                dampingFraction: LaunchpadMotion.folderDamping
            )
        ) {
            isFolderPresented = false
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (reduceMotion ? 0 : LaunchpadMotion.folderResponse + 0.04)
        ) {
            guard openedFolderID == closingFolderID,
                  !isFolderPresented
            else { return }
            openedFolderID = nil
            openedFolderOrigin = nil
        }
    }

    private func openAppFromFolder(_ app: InstalledApp) {
        openedFolderID = nil
        openedFolderOrigin = nil
        isFolderPresented = false
        library.open(app)
    }

    private func handleEscape() {
        if openedFolderID != nil {
            closeFolder()
        } else if showsSettings {
            showsSettings = false
        } else if isSearching {
            withAnimation(reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.quick)) {
                searchText = ""
                currentPage = 0
            }
            focusedControl = .search
        } else {
            dismissLauncher()
        }
    }

    private func matchesSearch(_ candidate: String, query: String) -> Bool {
        let normalizedQuery = compactSearchText(query)
        guard !normalizedQuery.isEmpty else { return true }

        let foldedCandidate = candidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if compactSearchText(foldedCandidate).contains(normalizedQuery) {
            return true
        }

        guard let latinCandidate = foldedCandidate.applyingTransform(
            .toLatin,
            reverse: false
        ) else { return false }
        let foldedLatin = latinCandidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        if compactSearchText(foldedLatin).contains(normalizedQuery) {
            return true
        }

        let initials = foldedLatin
            .split { !$0.isLetter && !$0.isNumber }
            .compactMap(\.first)
        return compactSearchText(String(initials)).contains(normalizedQuery)
    }

    private func compactSearchText(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    private func restoreBackup(_ document: LauncherBackupDocument) throws {
        guard document.formatVersion == LauncherBackupDocument.currentVersion else {
            throw LauncherBackupError.unsupportedVersion(document.formatVersion)
        }

        layoutStore.stageRestore(from: document.layout)
        settings.restore(from: document.settings)
        searchText = ""
        keyboardSelectedItemID = nil
        currentPage = 0
        closeFolderImmediately()
        library.reload(folders: settings.applicationFolders)
    }

    private func closeFolderImmediately() {
        openedFolderID = nil
        openedFolderOrigin = nil
        isFolderPresented = false
    }

    private func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        guard openedFolderID == nil,
              !showsSettings,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }

        if event.keyCode == 48 {
            let movesBackward = event.modifierFlags.contains(.shift)
            switch (focusedControl, movesBackward) {
            case (.search, false):
                focusedControl = .settings
            case (.settings, false):
                focusedControl = nil
                selectFirstItemOnCurrentPage()
            case (nil, false):
                focusedControl = .search
                keyboardSelectedItemID = nil
            case (.search, true):
                focusedControl = nil
                selectFirstItemOnCurrentPage()
            case (.settings, true):
                focusedControl = .search
            case (nil, true):
                focusedControl = .settings
                keyboardSelectedItemID = nil
            }
            return true
        }

        if focusedControl == .settings,
           event.keyCode == 36 || event.keyCode == 76 {
            showsSettings = true
            return true
        }

        if focusedControl == .search {
            guard event.keyCode == 125 else { return false }
            focusedControl = nil
            selectFirstItemOnCurrentPage()
            return true
        }

        switch event.keyCode {
        case 123:
            moveKeyboardSelection(by: -1)
        case 124:
            moveKeyboardSelection(by: 1)
        case 125:
            moveKeyboardSelection(by: settings.columnCount)
        case 126:
            moveKeyboardSelection(by: -settings.columnCount)
        case 36, 49, 76:
            guard keyboardSelectedItemID != nil else {
                selectFirstItemOnCurrentPage()
                return true
            }
            keyboardActivationRequest &+= 1
        case 115:
            currentPage = 0
            selectFirstItemOnCurrentPage()
        case 119:
            currentPage = max(0, pageCount - 1)
            selectFirstItemOnCurrentPage()
        case 116:
            currentPage = max(0, currentPage - 1)
            selectFirstItemOnCurrentPage()
        case 121:
            currentPage = min(max(0, pageCount - 1), currentPage + 1)
            selectFirstItemOnCurrentPage()
        default:
            return false
        }
        return true
    }

    private var pageCount: Int {
        let pageSize = max(1, settings.columnCount * settings.rowCount)
        return max(1, Int(ceil(Double(filteredItems.count) / Double(pageSize))))
    }

    private func moveKeyboardSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        focusedControl = nil

        let pageSize = settings.columnCount * settings.rowCount
        let fallbackIndex = min(currentPage * pageSize, filteredItems.count - 1)
        guard let currentIndex = keyboardSelectedItemID.flatMap({ selectedID in
            filteredItems.firstIndex(where: { $0.id == selectedID })
        }) else {
            keyboardSelectedItemID = filteredItems[fallbackIndex].id
            return
        }
        let destinationIndex = min(
            max(0, currentIndex + offset),
            filteredItems.count - 1
        )
        keyboardSelectedItemID = filteredItems[destinationIndex].id
        currentPage = destinationIndex / pageSize
    }

    private func selectFirstItemOnCurrentPage() {
        guard !filteredItems.isEmpty else {
            keyboardSelectedItemID = nil
            return
        }
        let pageSize = settings.columnCount * settings.rowCount
        let firstIndex = min(currentPage * pageSize, filteredItems.count - 1)
        keyboardSelectedItemID = filteredItems[firstIndex].id
    }

    private func keepKeyboardSelectionOnCurrentPage() {
        guard let selectedID = keyboardSelectedItemID,
              let selectedIndex = filteredItems.firstIndex(where: { $0.id == selectedID })
        else { return }
        let pageSize = settings.columnCount * settings.rowCount
        guard selectedIndex / pageSize != currentPage else { return }
        selectFirstItemOnCurrentPage()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let folderID: String
    let sourceOrigin: CGPoint?
    let isPresented: Bool
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
    @State private var selectedFolderPage: Int? = 0
    @State private var keyboardSelectedAppID: String?
    @FocusState private var isFolderNameFocused: Bool

    var body: some View {
        if let folder = layoutStore.folder(withID: folderID) {
            GeometryReader { geometry in
                let metrics = folderMetrics(in: geometry.size, appCount: folder.apps.count)
                let collapsedCenter = sourceOrigin ?? CGPoint(
                    x: metrics.panelFrame.midX,
                    y: metrics.panelFrame.midY
                )
                let panelCenter = isPresented
                    ? CGPoint(x: metrics.panelFrame.midX, y: metrics.panelFrame.midY)
                    : collapsedCenter
                let panelScale: CGFloat = isPresented ? 1 : 0.22
                let folderPages = displayedApps(in: folder).chunked(
                    into: metrics.pageCapacity
                )

                ZStack {
                    // The wallpaper behind the launcher is already blurred.
                    // A second full-screen NSVisualEffectView forces a costly
                    // live blur pass when the folder appears; a composited dim
                    // layer gives the same depth cue without the opening hitch.
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeAction)
                        .opacity(hasExitedFolder || !isPresented ? 0 : 1)
                        .accessibilityLabel("关闭文件夹")
                        .accessibilityHint("返回启动台")
                        .accessibilityAddTraits(.isButton)

                    VStack(spacing: 18) {
                        TextField("文件夹名称", text: $draftName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.97))
                            .multilineTextAlignment(.center)
                            .frame(width: 360, height: 30)
                            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                            .focused($isFolderNameFocused)
                            .accessibilityLabel("文件夹名称")
                            .accessibilityHint("输入新的名称后按回车保存")
                            .onSubmit(commitName)

                        FolderPageGrid(
                            pages: folderPages,
                            columns: metrics.columns,
                            gridHeight: metrics.gridHeight,
                            selectedPage: $selectedFolderPage,
                            draggingAppID: draggingAppID,
                            keyboardSelectedAppID: keyboardSelectedAppID,
                            openAction: openAction,
                            dragChanged: { app, location in
                                updateFolderDrag(
                                    app,
                                    at: location,
                                    folder: folder,
                                    panelFrame: metrics.panelFrame
                                )
                            },
                            dragEnded: { app, location in
                                finishDragging(
                                    app,
                                    at: location,
                                    panelFrame: metrics.panelFrame
                                )
                            }
                        )
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
                            .strokeBorder(
                                .white.opacity(colorSchemeContrast == .increased ? 0.8 : 0.22),
                                lineWidth: colorSchemeContrast == .increased ? 2 : 1
                            )
                    }
                    .shadow(color: .black.opacity(0.38), radius: 42, y: 18)
                    .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .onTapGesture { }
                    // Interpolate both center and size. This produces a true
                    // folder-to-panel expansion and the exact reverse path on
                    // close, independent of SwiftUI transform-anchor ordering.
                    .scaleEffect(panelScale)
                    .position(x: panelCenter.x, y: panelCenter.y)
                    .opacity(hasExitedFolder || !isPresented ? 0 : 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("文件夹 \(folder.name)")

                    if let draggingApp = folder.apps.first(where: { $0.id == draggingAppID }) {
                        FolderDragPreview(app: draggingApp)
                            .position(dragLocation)
                            .allowsHitTesting(false)
                            .zIndex(100)
                    }

                    LauncherKeyboardMonitor(action: handleFolderKeyboardEvent)
                        .frame(width: 0, height: 0)
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
                selectedFolderPage = 0
                keyboardSelectedAppID = nil
            }
            .onChange(of: folder.name) {
                draftName = folder.name
            }
            .onChange(of: folder.apps.map(\.id)) { _, appIDs in
                guard draggingAppID == nil else { return }
                previewAppIDs = appIDs
                if let keyboardSelectedAppID,
                   !appIDs.contains(keyboardSelectedAppID) {
                    self.keyboardSelectedAppID = nil
                }
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
            withAnimation(reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.quick)) {
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

        withAnimation(reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.standard)) {
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
        let rowsPerPage = 3
        let pageCapacity = visibleColumns * rowsPerPage
        let pageCount = max(1, Int(ceil(Double(appCount) / Double(pageCapacity))))
        let visibleItemCount = min(max(1, appCount), pageCapacity)
        let visibleRows = min(
            rowsPerPage,
            max(1, Int(ceil(Double(visibleItemCount) / Double(visibleColumns))))
        )
        let gridHeight = CGFloat(visibleRows) * 139
            + CGFloat(max(0, visibleRows - 1)) * 22
            + 12
        let chromeHeight: CGFloat = pageCount > 1 ? 120 : 94
        let panelHeight = min(
            size.height - 132,
            max(276, gridHeight + chromeHeight)
        )
        let panelFrame = CGRect(
            x: (size.width - panelWidth) / 2,
            y: (size.height - panelHeight) / 2 - 8,
            width: panelWidth,
            height: panelHeight
        )
        return FolderMetrics(
            columns: columns,
            pageCapacity: pageCapacity,
            gridHeight: gridHeight,
            panelFrame: panelFrame
        )
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

        withAnimation(reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.quick)) {
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

    private func handleFolderKeyboardEvent(_ event: NSEvent) -> Bool {
        guard draggingAppID == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let folder = layoutStore.folder(withID: folderID)
        else { return false }

        let apps = displayedApps(in: folder)
        guard !apps.isEmpty else { return false }
        let pageCapacity = max(1, folderPageCapacity(appCount: apps.count))

        if event.keyCode == 48 {
            if isFolderNameFocused {
                isFolderNameFocused = false
                selectFirstFolderApp(apps, pageCapacity: pageCapacity)
            } else if event.modifierFlags.contains(.shift) {
                keyboardSelectedAppID = nil
                isFolderNameFocused = true
            } else if keyboardSelectedAppID == nil {
                selectFirstFolderApp(apps, pageCapacity: pageCapacity)
            } else {
                keyboardSelectedAppID = nil
                isFolderNameFocused = true
            }
            return true
        }

        if isFolderNameFocused {
            guard event.keyCode == 125 else { return false }
            isFolderNameFocused = false
            selectFirstFolderApp(apps, pageCapacity: pageCapacity)
            return true
        }

        switch event.keyCode {
        case 123:
            moveFolderKeyboardSelection(by: -1, apps: apps, pageCapacity: pageCapacity)
        case 124:
            moveFolderKeyboardSelection(by: 1, apps: apps, pageCapacity: pageCapacity)
        case 125:
            moveFolderKeyboardSelection(
                by: folderColumnCount(appCount: apps.count),
                apps: apps,
                pageCapacity: pageCapacity
            )
        case 126:
            moveFolderKeyboardSelection(
                by: -folderColumnCount(appCount: apps.count),
                apps: apps,
                pageCapacity: pageCapacity
            )
        case 36, 49, 76:
            guard let keyboardSelectedAppID,
                  let app = apps.first(where: { $0.id == keyboardSelectedAppID })
            else {
                selectFirstFolderApp(apps, pageCapacity: pageCapacity)
                return true
            }
            openAction(app)
        case 115:
            selectFolderPage(0, apps: apps, pageCapacity: pageCapacity)
        case 119:
            selectFolderPage(
                max(0, Int(ceil(Double(apps.count) / Double(pageCapacity))) - 1),
                apps: apps,
                pageCapacity: pageCapacity
            )
        case 116:
            selectFolderPage(
                max(0, (selectedFolderPage ?? 0) - 1),
                apps: apps,
                pageCapacity: pageCapacity
            )
        case 121:
            let lastPage = max(0, Int(ceil(Double(apps.count) / Double(pageCapacity))) - 1)
            selectFolderPage(
                min(lastPage, (selectedFolderPage ?? 0) + 1),
                apps: apps,
                pageCapacity: pageCapacity
            )
        default:
            return false
        }
        return true
    }

    private func folderColumnCount(appCount: Int) -> Int {
        let maximumColumns = min(
            7,
            max(4, Int((currentFolderScreenSize.width - 150) / 150))
        )
        return min(maximumColumns, max(4, appCount))
    }

    private var currentFolderScreenSize: CGSize {
        LauncherWindowController.shared.activeScreen?.frame.size
            ?? NSScreen.main?.frame.size
            ?? CGSize(width: 1440, height: 900)
    }

    private func folderPageCapacity(appCount: Int) -> Int {
        folderColumnCount(appCount: appCount) * 3
    }

    private func selectFirstFolderApp(_ apps: [InstalledApp], pageCapacity: Int) {
        let index = min((selectedFolderPage ?? 0) * pageCapacity, apps.count - 1)
        keyboardSelectedAppID = apps[index].id
    }

    private func moveFolderKeyboardSelection(
        by offset: Int,
        apps: [InstalledApp],
        pageCapacity: Int
    ) {
        guard let currentIndex = keyboardSelectedAppID.flatMap({ selectedID in
            apps.firstIndex(where: { $0.id == selectedID })
        }) else {
            selectFirstFolderApp(apps, pageCapacity: pageCapacity)
            return
        }
        let destination = min(max(0, currentIndex + offset), apps.count - 1)
        keyboardSelectedAppID = apps[destination].id
        selectedFolderPage = destination / pageCapacity
    }

    private func selectFolderPage(
        _ page: Int,
        apps: [InstalledApp],
        pageCapacity: Int
    ) {
        selectedFolderPage = page
        let index = min(page * pageCapacity, apps.count - 1)
        keyboardSelectedAppID = apps[index].id
    }
}

private struct FolderMetrics {
    let columns: [GridItem]
    let pageCapacity: Int
    let gridHeight: CGFloat
    let panelFrame: CGRect
}

private struct FolderPageGrid: View {
    let pages: [[InstalledApp]]
    let columns: [GridItem]
    let gridHeight: CGFloat
    @Binding var selectedPage: Int?
    let draggingAppID: String?
    let keyboardSelectedAppID: String?
    let openAction: (InstalledApp) -> Void
    let dragChanged: (InstalledApp, CGPoint) -> Void
    let dragEnded: (InstalledApp, CGPoint) -> Void

    var body: some View {
        VStack(spacing: 18) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { pageIndex in
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(pages[pageIndex]) { app in
                                FolderPageAppCell(
                                    app: app,
                                    isDragging: draggingAppID == app.id,
                                    isKeyboardFocused: keyboardSelectedAppID == app.id,
                                    openAction: { openAction(app) },
                                    dragChanged: { dragChanged(app, $0) },
                                    dragEnded: { dragEnded(app, $0) }
                                )
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 6)
                        .containerRelativeFrame(.horizontal)
                        .id(pageIndex)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedPage)
            .frame(height: gridHeight)

            if pages.count > 1 {
                FolderPageIndicator(
                    pageCount: pages.count,
                    selectedPage: $selectedPage
                )
            }
        }
        .onAppear(perform: clampSelectedPage)
        .onChange(of: pages.count) { _, _ in
            clampSelectedPage()
        }
    }

    private func clampSelectedPage() {
        let lastPage = max(0, pages.count - 1)
        selectedPage = min(selectedPage ?? 0, lastPage)
    }
}

private struct FolderPageIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    let pageCount: Int
    @Binding var selectedPage: Int?

    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<pageCount, id: \.self) { pageIndex in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.standard)) {
                        selectedPage = pageIndex
                    }
                } label: {
                    Circle()
                        .fill(
                            .white.opacity(
                                selectedPage == pageIndex ? 0.94 : 0.3
                            )
                        )
                        .frame(
                            width: selectedPage == pageIndex && differentiateWithoutColor ? 9 : 7,
                            height: selectedPage == pageIndex && differentiateWithoutColor ? 9 : 7
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("文件夹第 \(pageIndex + 1) 页")
                .accessibilityValue(selectedPage == pageIndex ? "当前页" : "")
            }
        }
        .frame(height: 8)
    }
}

private struct FolderPageAppCell: View {
    let app: InstalledApp
    let isDragging: Bool
    let isKeyboardFocused: Bool
    let openAction: () -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: (CGPoint) -> Void

    var body: some View {
        FolderAppTile(
            app: app,
            isDragging: isDragging,
            isKeyboardFocused: isKeyboardFocused,
            openAction: openAction,
            revealAction: {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            },
            dragChanged: dragChanged,
            dragEnded: dragEnded
        )
        .zIndex(isDragging ? 2 : 0)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let app: InstalledApp
    let isDragging: Bool
    let isKeyboardFocused: Bool
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
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(
                            .white.opacity(colorSchemeContrast == .increased ? 1 : 0.78),
                            lineWidth: colorSchemeContrast == .increased ? 3 : 2
                        )
                        .padding(-7)
                        .opacity(isKeyboardFocused ? 1 : 0)
                }

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
        .animation(
            reduceMotion ? nil : .easeOut(duration: LaunchpadMotion.quick),
            value: isDragging
        )
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue("应用")
        .accessibilityHint("按下以打开应用，也可以拖动调整位置")
        .accessibilityAddTraits(.isButton)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.92 : 1))
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .spring(response: LaunchpadMotion.standard, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

private struct DesktopWallpaperView: View {
    @State private var wallpaper = Self.loadWallpaper()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let wallpaper {
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
        .onReceive(
            NotificationCenter.default.publisher(for: .launcherScreenDidChange)
        ) { _ in
            wallpaper = Self.loadWallpaper()
        }
    }

    private static func loadWallpaper() -> NSImage? {
        let screen = LauncherWindowController.shared.activeScreen
            ?? NSScreen.screenContainingMouse
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen,
              let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else {
            return nil
        }

        return NSImage(contentsOf: url)
    }
}

private struct LauncherKeyboardMonitor: NSViewRepresentable {
    let action: (NSEvent) -> Bool

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
        var action: (NSEvent) -> Bool
        private var monitor: Any?

        init(action: @escaping (NSEvent) -> Bool) {
            self.action = action
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard NSApplication.shared.isActive,
                      event.keyCode != 53,
                      self?.action(event) == true
                else { return event }
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
