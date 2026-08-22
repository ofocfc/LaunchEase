import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct LauncherSettingsBackup: Codable {
    let applicationFolderPaths: [String]
    let rowCount: Int
    let columnCount: Int
    let appIconChoice: String
}

struct LauncherBackupDocument: Codable {
    static let currentVersion = 1

    let formatVersion: Int
    let exportedAt: Date
    let settings: LauncherSettingsBackup
    let layout: LaunchpadLayoutBackup
}

enum LauncherBackupError: LocalizedError {
    case unsupportedVersion(Int)
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "不支持版本为 \(version) 的备份文件。"
        case .fileTooLarge:
            return "备份文件过大，无法导入。"
        }
    }
}

enum LauncherIconChoice: String, CaseIterable, Identifiable {
    case softColor
    case minimal
    case glass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .softColor: "柔彩"
        case .minimal: "极简"
        case .glass: "玻璃"
        }
    }

    var assetName: String {
        switch self {
        case .softColor: "LauncherIconSoftColor"
        case .minimal: "LauncherIconMinimal"
        case .glass: "LauncherIconGlass"
        }
    }

    var image: NSImage? {
        NSImage(named: NSImage.Name(assetName))
    }

    func apply() {
        guard let image else { return }
        NSApplication.shared.applicationIconImage = image
    }
}

@MainActor
final class LauncherSettings: ObservableObject {
    static let defaultApplicationFolders = [
        "/Applications",
        "/System/Applications",
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .path
    ]

    @Published var applicationFolderPaths: [String] {
        didSet {
            defaults.set(applicationFolderPaths, forKey: Keys.applicationFolderPaths)
        }
    }

    @Published var rowCount: Int {
        didSet {
            let value = min(max(rowCount, 3), 6)
            if rowCount != value {
                rowCount = value
                return
            }
            defaults.set(rowCount, forKey: Keys.rowCount)
        }
    }

    @Published var columnCount: Int {
        didSet {
            let value = min(max(columnCount, 4), 8)
            if columnCount != value {
                columnCount = value
                return
            }
            defaults.set(columnCount, forKey: Keys.columnCount)
        }
    }

    @Published var appIconChoice: LauncherIconChoice {
        didSet {
            defaults.set(appIconChoice.rawValue, forKey: Keys.appIconChoice)
            appIconChoice.apply()
        }
    }

    var applicationFolders: [URL] {
        var paths = applicationFolderPaths

        // Finder's “Applications” sidebar item is a merged presentation of
        // user-installed and system applications. Match that expectation when
        // the user selects /Applications explicitly.
        if paths.contains("/Applications"), !paths.contains("/System/Applications") {
            paths.append("/System/Applications")
        }

        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let savedFolders = defaults.stringArray(forKey: Keys.applicationFolderPaths)
        applicationFolderPaths = savedFolders?.isEmpty == false
            ? savedFolders!
            : Self.defaultApplicationFolders

        let savedRows = defaults.integer(forKey: Keys.rowCount)
        rowCount = savedRows == 0 ? 5 : min(max(savedRows, 3), 6)

        let savedColumns = defaults.integer(forKey: Keys.columnCount)
        columnCount = savedColumns == 0 ? 7 : min(max(savedColumns, 4), 8)

        let savedIconChoice = defaults.string(forKey: Keys.appIconChoice)
            .flatMap(LauncherIconChoice.init(rawValue:))
        appIconChoice = savedIconChoice ?? .glass
        appIconChoice.apply()
    }

    func addApplicationFolders(_ urls: [URL]) {
        var paths = applicationFolderPaths
        var knownPaths = Set(paths)

        for url in urls {
            let path = url.standardizedFileURL.path
            if knownPaths.insert(path).inserted {
                paths.append(path)
            }
        }

        applicationFolderPaths = paths
    }

    func removeApplicationFolder(_ path: String) {
        applicationFolderPaths.removeAll { $0 == path }
    }

    func restoreDefaultFolders() {
        applicationFolderPaths = Self.defaultApplicationFolders
    }

    func makeBackup() -> LauncherSettingsBackup {
        LauncherSettingsBackup(
            applicationFolderPaths: applicationFolderPaths,
            rowCount: rowCount,
            columnCount: columnCount,
            appIconChoice: appIconChoice.rawValue
        )
    }

    func restore(from backup: LauncherSettingsBackup) {
        var insertedPaths = Set<String>()
        applicationFolderPaths = backup.applicationFolderPaths
            .prefix(128)
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            .filter { !$0.isEmpty && insertedPaths.insert($0).inserted }
        rowCount = min(max(backup.rowCount, 3), 6)
        columnCount = min(max(backup.columnCount, 4), 8)
        if let iconChoice = LauncherIconChoice(rawValue: backup.appIconChoice) {
            appIconChoice = iconChoice
        }
    }

    private enum Keys {
        static let applicationFolderPaths = "launcher.applicationFolderPaths"
        static let rowCount = "launcher.gridRows"
        static let columnCount = "launcher.gridColumns"
        static let appIconChoice = "launcher.appIconChoice"
    }
}

struct LauncherSettingsView: View {
    @ObservedObject var settings: LauncherSettings
    @ObservedObject var layoutStore: LaunchpadLayoutStore
    @Binding var isPresented: Bool
    let importAction: (LauncherBackupDocument) throws -> Void
    @State private var backupNotice: BackupNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("启动台设置")
                    .font(.system(size: 18, weight: .semibold))

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭启动台设置")
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("应用文件夹", systemImage: "folder")
                    .font(.system(size: 14, weight: .semibold))

                VStack(spacing: 0) {
                    if settings.applicationFolderPaths.isEmpty {
                        Text("尚未添加扫描目录")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    } else {
                        ForEach(settings.applicationFolderPaths, id: \.self) { path in
                            folderRow(path)

                            if path != settings.applicationFolderPaths.last {
                                Divider()
                                    .padding(.leading, 36)
                            }
                        }
                    }
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 12) {
                    Button("添加文件夹…", systemImage: "plus") {
                        chooseApplicationFolders()
                    }

                    Button("恢复默认", systemImage: "arrow.counterclockwise") {
                        settings.restoreDefaultFolders()
                    }

                    Spacer()
                }
                .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("应用图标", systemImage: "app.dashed")
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 12) {
                    ForEach(LauncherIconChoice.allCases) { choice in
                        iconChoiceButton(choice)
                    }
                }

                Text("选择后会立即更新程序坞图标，并在下次启动时保留。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Label("图标布局", systemImage: "square.grid.3x3")
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 18) {
                    layoutStepper(
                        title: "行数",
                        value: $settings.rowCount,
                        range: 3...6
                    )

                    layoutStepper(
                        title: "列数",
                        value: $settings.columnCount,
                        range: 4...8
                    )
                }

                Text("当前每页显示 \(settings.rowCount * settings.columnCount) 个应用，修改后立即重新分页。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label("设置备份", systemImage: "externaldrive.badge.timemachine")
                    .font(.system(size: 14, weight: .semibold))

                HStack(spacing: 12) {
                    Button("导出备份…", systemImage: "square.and.arrow.up") {
                        exportBackup()
                    }

                    Button("导入备份…", systemImage: "square.and.arrow.down") {
                        importBackup()
                    }

                    Spacer()
                }
                .controlSize(.small)

                Text("备份包含扫描目录、行列数、图标主题、应用顺序和文件夹。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 430)
        .alert(item: $backupNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.title = "导出 LaunchEase 备份"
        panel.prompt = "导出"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "LaunchEase-Backup.json"

        LauncherWindowController.shared.presentSavePanel(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let document = LauncherBackupDocument(
                    formatVersion: LauncherBackupDocument.currentVersion,
                    exportedAt: Date(),
                    settings: settings.makeBackup(),
                    layout: layoutStore.makeBackup()
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(document)
                try data.write(to: url, options: .atomic)
                backupNotice = BackupNotice(
                    title: "导出成功",
                    message: "备份已保存为 \(url.lastPathComponent)。"
                )
            } catch {
                showBackupError(error)
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.title = "导入 LaunchEase 备份"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        LauncherWindowController.shared.presentFolderPicker(panel) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 5_000_000 else {
                    throw LauncherBackupError.fileTooLarge
                }
                let data = try Data(contentsOf: url)
                let document = try JSONDecoder().decode(
                    LauncherBackupDocument.self,
                    from: data
                )
                try importAction(document)
                backupNotice = BackupNotice(
                    title: "导入成功",
                    message: "正在重新扫描应用并恢复布局。"
                )
            } catch {
                showBackupError(error)
            }
        }
    }

    private func showBackupError(_ error: Error) {
        backupNotice = BackupNotice(
            title: "无法处理备份",
            message: error.localizedDescription
        )
    }

    private struct BackupNotice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private func iconChoiceButton(_ choice: LauncherIconChoice) -> some View {
        Button {
            settings.appIconChoice = choice
        } label: {
            VStack(spacing: 7) {
                Group {
                    if let image = choice.image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: "app")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 52, height: 52)

                Text(choice.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                settings.appIconChoice == choice
                    ? Color.accentColor.opacity(0.14)
                    : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        settings.appIconChoice == choice
                            ? Color.accentColor.opacity(0.75)
                            : Color.primary.opacity(0.08),
                        lineWidth: settings.appIconChoice == choice ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("应用图标：\(choice.title)")
        .accessibilityValue(settings.appIconChoice == choice ? "已选择" : "未选择")
        .accessibilityHint("选择后立即更新程序坞图标")
    }

    private func folderRow(_ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button {
                settings.removeApplicationFolder(path)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("停止扫描此文件夹")
            .accessibilityLabel("移除 \(URL(fileURLWithPath: path).lastPathComponent)")
            .accessibilityHint("停止扫描此文件夹")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private func layoutStepper(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))

            Spacer()

            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 24)
            }
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue)")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func chooseApplicationFolders() {
        let panel = NSOpenPanel()
        panel.title = "选择要扫描的应用文件夹"
        panel.prompt = "添加"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        isPresented = false
        DispatchQueue.main.async {
            LauncherWindowController.shared.presentFolderPicker(panel) { response in
                guard response == .OK else { return }
                settings.addApplicationFolders(panel.urls)
            }
        }
    }
}
