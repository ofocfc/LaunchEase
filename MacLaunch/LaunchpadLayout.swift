import AppKit
import Combine
import Foundation

struct LaunchpadFolder: Identifiable {
    let id: String
    var name: String
    var apps: [InstalledApp]
}

struct LaunchpadItem: Identifiable {
    enum Content {
        case app(InstalledApp)
        case folder(LaunchpadFolder)
    }

    let content: Content

    var id: String {
        switch content {
        case .app(let app):
            return app.id
        case .folder(let folder):
            return folder.id
        }
    }

    var name: String {
        switch content {
        case .app(let app):
            return app.name
        case .folder(let folder):
            return folder.name
        }
    }

    var app: InstalledApp? {
        guard case .app(let app) = content else { return nil }
        return app
    }

    var folder: LaunchpadFolder? {
        guard case .folder(let folder) = content else { return nil }
        return folder
    }
}

struct LaunchpadLayoutBackup: Codable {
    struct Folder: Codable {
        let id: String
        let name: String
        let appIDs: [String]
    }

    let order: [String]
    let folders: [Folder]
}

@MainActor
final class LaunchpadLayoutStore: ObservableObject {
    @Published private(set) var items: [LaunchpadItem] = []

    private struct StoredLayout: Codable {
        var order: [String]
        var folders: [StoredFolder]
    }

    private struct StoredFolder: Codable {
        var id: String
        var name: String
        var appIDs: [String]
    }

    private let defaults: UserDefaults
    private var storedLayout: StoredLayout

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.layout),
           let layout = try? JSONDecoder().decode(StoredLayout.self, from: data) {
            storedLayout = layout
        } else {
            storedLayout = StoredLayout(order: [], folders: [])
        }
    }

    func reconcile(apps: [InstalledApp]) {
        let appsByID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var claimedAppIDs = Set<String>()
        var foldersByID: [String: LaunchpadFolder] = [:]
        var dissolvedAppsByFolderID: [String: InstalledApp] = [:]

        for storedFolder in storedLayout.folders {
            let folderApps = storedFolder.appIDs.compactMap { appID -> InstalledApp? in
                guard claimedAppIDs.insert(appID).inserted else { return nil }
                return appsByID[appID]
            }

            if folderApps.count == 1, let remainingApp = folderApps.first {
                dissolvedAppsByFolderID[storedFolder.id] = remainingApp
            } else if folderApps.count >= 2 {
                let storedName = storedFolder.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                foldersByID[storedFolder.id] = LaunchpadFolder(
                    id: storedFolder.id,
                    name: storedName.isEmpty ? "文件夹" : storedName,
                    apps: folderApps
                )
            }
        }

        var nextItems: [LaunchpadItem] = []
        var insertedItemIDs = Set<String>()

        for itemID in storedLayout.order {
            if let folder = foldersByID[itemID],
               insertedItemIDs.insert(folder.id).inserted {
                nextItems.append(LaunchpadItem(content: .folder(folder)))
            } else if let app = dissolvedAppsByFolderID[itemID],
                      insertedItemIDs.insert(app.id).inserted {
                nextItems.append(LaunchpadItem(content: .app(app)))
            } else if let app = appsByID[itemID],
                      !claimedAppIDs.contains(itemID),
                      insertedItemIDs.insert(app.id).inserted {
                nextItems.append(LaunchpadItem(content: .app(app)))
            }
        }

        for folder in foldersByID.values where insertedItemIDs.insert(folder.id).inserted {
            nextItems.append(LaunchpadItem(content: .folder(folder)))
        }

        for app in apps where !claimedAppIDs.contains(app.id) && insertedItemIDs.insert(app.id).inserted {
            nextItems.append(LaunchpadItem(content: .app(app)))
        }

        items = nextItems
        persistCurrentItems()
    }

    func move(_ sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              let originalTargetIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        let movesForward = sourceIndex < originalTargetIndex
        let item = items.remove(at: sourceIndex)
        guard let targetIndex = items.firstIndex(where: { $0.id == targetID }) else {
            items.insert(item, at: min(sourceIndex, items.count))
            return
        }

        let insertionIndex = targetIndex + (movesForward ? 1 : 0)
        items.insert(item, at: min(insertionIndex, items.count))
        persistCurrentItems()
    }

    func move(_ sourceID: String, to destinationIndex: Int) {
        guard let sourceIndex = items.firstIndex(where: { $0.id == sourceID }) else {
            return
        }

        let item = items.remove(at: sourceIndex)
        let insertionIndex = min(max(0, destinationIndex), items.count)
        items.insert(item, at: insertionIndex)
        persistCurrentItems()
    }

    func merge(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = items.firstIndex(where: { $0.id == sourceID }),
              let sourceApp = items[sourceIndex].app,
              let targetIndex = items.firstIndex(where: { $0.id == targetID })
        else { return }

        switch items[targetIndex].content {
        case .app(let targetApp):
            let insertionIndex = targetIndex - (sourceIndex < targetIndex ? 1 : 0)
            items.remove(at: sourceIndex)
            guard let adjustedTargetIndex = items.firstIndex(where: { $0.id == targetID }) else {
                return
            }
            items.remove(at: adjustedTargetIndex)

            let folder = LaunchpadFolder(
                id: "folder:\(UUID().uuidString)",
                name: "文件夹",
                apps: [targetApp, sourceApp]
            )
            items.insert(
                LaunchpadItem(content: .folder(folder)),
                at: min(insertionIndex, items.count)
            )

        case .folder(var folder):
            guard !folder.apps.contains(where: { $0.id == sourceApp.id }) else { return }
            items.remove(at: sourceIndex)
            guard let adjustedTargetIndex = items.firstIndex(where: { $0.id == targetID }) else {
                return
            }
            folder.apps.append(sourceApp)
            items[adjustedTargetIndex] = LaunchpadItem(content: .folder(folder))
        }

        persistCurrentItems()
    }

    @discardableResult
    func removeApp(_ appID: String, fromFolder folderID: String) -> Bool {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID }),
              var folder = items[folderIndex].folder,
              let appIndex = folder.apps.firstIndex(where: { $0.id == appID })
        else { return false }

        let extractedApp = folder.apps.remove(at: appIndex)

        if folder.apps.isEmpty {
            items.remove(at: folderIndex)
            items.insert(
                LaunchpadItem(content: .app(extractedApp)),
                at: min(folderIndex, items.count)
            )
        } else if folder.apps.count == 1, let remainingApp = folder.apps.first {
            // Launchpad automatically dissolves a folder once only one app is
            // left. Keep both apps next to the former folder position.
            items.remove(at: folderIndex)
            items.insert(
                LaunchpadItem(content: .app(remainingApp)),
                at: min(folderIndex, items.count)
            )
            items.insert(
                LaunchpadItem(content: .app(extractedApp)),
                at: min(folderIndex + 1, items.count)
            )
        } else {
            items[folderIndex] = LaunchpadItem(content: .folder(folder))
            items.insert(
                LaunchpadItem(content: .app(extractedApp)),
                at: min(folderIndex + 1, items.count)
            )
        }

        persistCurrentItems()
        return true
    }

    @discardableResult
    func moveApp(
        _ appID: String,
        outOfFolder folderID: String,
        to destinationIndex: Int
    ) -> Bool {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID }),
              var folder = items[folderIndex].folder,
              let appIndex = folder.apps.firstIndex(where: { $0.id == appID })
        else { return false }

        let extractedApp = folder.apps.remove(at: appIndex)

        if folder.apps.isEmpty {
            items.remove(at: folderIndex)
        } else if folder.apps.count == 1, let remainingApp = folder.apps.first {
            items[folderIndex] = LaunchpadItem(content: .app(remainingApp))
        } else {
            items[folderIndex] = LaunchpadItem(content: .folder(folder))
        }

        items.insert(
            LaunchpadItem(content: .app(extractedApp)),
            at: min(max(0, destinationIndex), items.count)
        )
        persistCurrentItems()
        return true
    }

    func renameFolder(_ folderID: String, to proposedName: String) {
        let proposedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = proposedName.isEmpty ? "文件夹" : proposedName
        guard let index = items.firstIndex(where: { $0.id == folderID }),
              var folder = items[index].folder
        else { return }

        folder.name = name
        items[index] = LaunchpadItem(content: .folder(folder))
        persistCurrentItems()
    }

    func reorderApps(inFolder folderID: String, orderedAppIDs: [String]) {
        guard let folderIndex = items.firstIndex(where: { $0.id == folderID }),
              var folder = items[folderIndex].folder
        else { return }

        let appsByID = Dictionary(uniqueKeysWithValues: folder.apps.map { ($0.id, $0) })
        var insertedIDs = Set<String>()
        var reorderedApps = orderedAppIDs.compactMap { appID -> InstalledApp? in
            guard insertedIDs.insert(appID).inserted else { return nil }
            return appsByID[appID]
        }
        reorderedApps.append(
            contentsOf: folder.apps.filter { insertedIDs.insert($0.id).inserted }
        )

        guard reorderedApps.map(\.id) != folder.apps.map(\.id) else { return }
        folder.apps = reorderedApps
        items[folderIndex] = LaunchpadItem(content: .folder(folder))
        persistCurrentItems()
    }

    func folder(withID folderID: String) -> LaunchpadFolder? {
        items.first(where: { $0.id == folderID })?.folder
    }

    func makeBackup() -> LaunchpadLayoutBackup {
        LaunchpadLayoutBackup(
            order: storedLayout.order,
            folders: storedLayout.folders.map { folder in
                LaunchpadLayoutBackup.Folder(
                    id: folder.id,
                    name: folder.name,
                    appIDs: folder.appIDs
                )
            }
        )
    }

    func stageRestore(from backup: LaunchpadLayoutBackup) {
        var insertedOrderIDs = Set<String>()
        let order = backup.order.filter { insertedOrderIDs.insert($0).inserted }
        var insertedFolderIDs = Set<String>()
        let folders = backup.folders.compactMap { folder -> StoredFolder? in
            let folderID = folder.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folderID.isEmpty,
                  insertedFolderIDs.insert(folderID).inserted
            else { return nil }

            var insertedAppIDs = Set<String>()
            let appIDs = folder.appIDs.filter { appID in
                !appID.isEmpty && insertedAppIDs.insert(appID).inserted
            }
            let proposedName = folder.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return StoredFolder(
                id: folderID,
                name: proposedName.isEmpty ? "文件夹" : proposedName,
                appIDs: appIDs
            )
        }

        storedLayout = StoredLayout(order: order, folders: folders)
        persistStoredLayout()
    }

    private func persistCurrentItems() {
        storedLayout = StoredLayout(
            order: items.map(\.id),
            folders: items.compactMap { item in
                guard let folder = item.folder else { return nil }
                return StoredFolder(
                    id: folder.id,
                    name: folder.name,
                    appIDs: folder.apps.map(\.id)
                )
            }
        )

        persistStoredLayout()
    }

    private func persistStoredLayout() {
        guard let data = try? JSONEncoder().encode(storedLayout) else { return }
        defaults.set(data, forKey: Keys.layout)
    }

    private enum Keys {
        static let layout = "launcher.iconLayout.v1"
    }
}
