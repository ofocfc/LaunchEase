//
//  MacLaunchApp.swift
//  MacLaunch
//
//  Created by 随便 on 2026/8/14.
//

import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class LauncherWindowController: NSObject, NSWindowDelegate {
    static let shared = LauncherWindowController()

    private var launcherPanel: LauncherPanel?

    var isVisible: Bool {
        launcherPanel?.isVisible == true
    }

    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let panel = launcherPanel ?? makePanel(on: screen)
        launcherPanel = panel

        // A borderless panel in the current Space gives the native Launchpad effect.
        // It never creates a macOS full-screen Space; the system Dock stays above it.
        panel.setFrame(screen.frame, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hide() {
        launcherPanel?.orderOut(nil)
        NSApplication.shared.hide(nil)
    }

    func presentFolderPicker(
        _ panel: NSOpenPanel,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let launcherPanel, launcherPanel.isVisible {
            panel.beginSheetModal(for: launcherPanel, completionHandler: completion)
        } else {
            panel.level = .modalPanel
            panel.begin(completionHandler: completion)
        }
    }

    private func makePanel(on screen: NSScreen) -> LauncherPanel {
        let panel = LauncherPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        panel.contentViewController = NSHostingController(rootView: ContentView())
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        return panel
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        LauncherWindowController.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if LauncherWindowController.shared.isVisible {
            LauncherWindowController.shared.hide()
        } else {
            LauncherWindowController.shared.show()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

@main
struct MacLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
