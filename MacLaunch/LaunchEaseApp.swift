//
//  LaunchEaseApp.swift
//  LaunchEase
//
//  Created by 随便 on 2026/8/14.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let launcherScreenDidChange = Notification.Name(
        "LaunchEase.launcherScreenDidChange"
    )
}

extension NSScreen {
    static var screenContainingMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TrackpadPinchMonitor {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var accumulatedMagnification: CGFloat = 0
    private var maximumTouchCount = 0
    private var hasTriggeredCurrentGesture = false
    private var lastTriggerUptime: TimeInterval = 0

    func start() {
        guard localMonitor == nil, globalMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) {
            [weak self] event in
            self?.handle(event)
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        resetGesture()
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            resetGesture()
        }

        maximumTouchCount = max(maximumTouchCount, event.allTouches().count)
        accumulatedMagnification += event.magnification

        let now = ProcessInfo.processInfo.systemUptime
        let isFourFingerGesture = maximumTouchCount >= 4
        let isOutsideCooldown = now - lastTriggerUptime > 0.75
        let opensLauncher = !LauncherWindowController.shared.isVisible
            && accumulatedMagnification <= -0.18
        let closesLauncher = LauncherWindowController.shared.isVisible
            && accumulatedMagnification >= 0.18

        if !hasTriggeredCurrentGesture,
           isFourFingerGesture,
           isOutsideCooldown,
           opensLauncher || closesLauncher {
            hasTriggeredCurrentGesture = true
            lastTriggerUptime = now
            NSHapticFeedbackManager.defaultPerformer.perform(
                .alignment,
                performanceTime: .now
            )
            if opensLauncher {
                LauncherWindowController.shared.show()
            } else {
                LauncherWindowController.shared.hide()
            }
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let handled = hasTriggeredCurrentGesture
            resetGesture()
            return handled
        }
        return hasTriggeredCurrentGesture
    }

    private func resetGesture() {
        accumulatedMagnification = 0
        maximumTouchCount = 0
        hasTriggeredCurrentGesture = false
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}

@MainActor
final class LauncherWindowController: NSObject, NSWindowDelegate {
    static let shared = LauncherWindowController()

    private var launcherPanel: LauncherPanel?
    private var presentationIntent = false
    private var lastDockIconClickUptime: TimeInterval = 0

    var isVisible: Bool {
        launcherPanel?.isVisible == true
    }

    var activeScreen: NSScreen? {
        launcherPanel?.screen
    }

    func show() {
        guard let screen = NSScreen.screenContainingMouse
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }
        presentationIntent = true

        let panel = launcherPanel ?? makePanel(on: screen)
        launcherPanel = panel

        // A borderless panel in the current Space gives the native Launchpad effect.
        // It never creates a macOS full-screen Space; the system Dock stays above it.
        panel.setFrame(screen.frame, display: true, animate: false)
        panel.orderFrontRegardless()
        panel.makeKey()

        NotificationCenter.default.post(name: .launcherScreenDidChange, object: screen)

        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func hide() {
        presentationIntent = false
        launcherPanel?.orderOut(nil)
        NSApplication.shared.hide(nil)
    }

    func handleDockIconClick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDockIconClickUptime > 0.22 else { return }
        lastDockIconClickUptime = now

        // AppKit can make a retained panel visible while it is delivering the
        // reopen callback. Use our pre-existing intent instead of the panel's
        // transient `isVisible` value, otherwise a show request becomes an
        // immediate hide and the launcher only flashes once.
        if presentationIntent {
            hide()
        } else {
            show()
        }
    }

    func noteHiddenBySystem() {
        presentationIntent = false
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

    func presentSavePanel(
        _ panel: NSSavePanel,
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let trackpadPinchMonitor = TrackpadPinchMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        trackpadPinchMonitor.start()
        LauncherWindowController.shared.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LauncherWindowController.shared.handleDockIconClick()
        // The panel has already been handled explicitly; prevent AppKit from
        // performing a second default reopen after this callback returns.
        return false
    }

    func applicationDidResignActive(_ notification: Notification) {
        LauncherWindowController.shared.noteHiddenBySystem()
    }

    func applicationDidHide(_ notification: Notification) {
        LauncherWindowController.shared.noteHiddenBySystem()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}

@main
struct LaunchEaseApp: App {
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
