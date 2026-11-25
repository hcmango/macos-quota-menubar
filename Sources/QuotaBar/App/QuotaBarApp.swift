import AppKit
import Combine
import QuartzCore
import SwiftUI

@main
enum QuotaBarMain {
    @MainActor private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
    }
}

@MainActor
private final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = QuotaStore()
    private let clock = PopoverClock()
    private let statusOverlay = QuotaStatusOverlayView()
    private let popover = NSPopover()
    private var displayMode: StatusBarDisplayMode = StatusBarDisplayMode.load()
    private var cancellable: AnyCancellable?
    private var popoverTimer: Timer?
    private var drawerAnimationTimer: Timer?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var lastRenderState: StatusRenderState?

    private var currentPopoverHeight: CGFloat = 0
    private var baseCollapsedHeight: CGFloat = 0
    private var fullDrawerHeight: CGFloat = 0
    private var isAnimatingDrawer = false

    override init() {
        super.init()

        configureStatusButton()
        configurePopover()
        updateStatusView()

        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.popover.isShown {
                    self.clock.now = Date()
                }
                self.updateStatusView()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusViewForEnvironmentChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(updateStatusViewForEnvironmentChange),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(updateStatusViewForEnvironmentChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        popoverTimer?.invalidate()
        drawerAnimationTimer?.invalidate()
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.toolTip = nil
        button.target = self
        button.action = #selector(handleStatusButtonClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusOverlay.frame = button.bounds
        statusOverlay.autoresizingMask = [.width, .height]
        button.addSubview(statusOverlay)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let rootView = QuotaPopoverView(
            store: store,
            clock: clock,
            onRefresh: { [weak self] in
                guard let self else { return }
                self.clock.now = Date()
                Task { await self.store.refresh() }
            },
            onToggleResetCredits: { [weak self] measuredDrawerHeight in
                self?.toggleResetCreditsDrawer(fullHeight: measuredDrawerHeight)
            },
            onDrawerHeightMeasured: { [weak self] measuredDrawerHeight in
                self?.handleDrawerHeightMeasured(measuredDrawerHeight)
            },
            onContentHeightChange: { [weak self] newHeight in
                self?.handleContentHeightChange(newHeight)
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        popover.contentViewController = hostingController
    }

    private func handleDrawerHeightMeasured(_ measuredHeight: CGFloat) {
        fullDrawerHeight = measuredHeight
        if !isAnimatingDrawer && clock.resetCreditsTargetExpanded {
            let newDrawerHeight = PopoverMotion.pixelAligned(measuredHeight)
            if abs(clock.animatedDrawerHeight - newDrawerHeight) > 0.5 {
                clock.animatedDrawerHeight = newDrawerHeight
                applyPopoverHeightImmediately(baseCollapsedHeight + newDrawerHeight)
            }
        }
    }

    private func handleContentHeightChange(_ measuredTotalHeight: CGFloat) {
        guard !isAnimatingDrawer else { return }
        let clamped = max(80, PopoverMotion.pixelAligned(measuredTotalHeight))
        baseCollapsedHeight = max(80, PopoverMotion.pixelAligned(clamped - clock.animatedDrawerHeight))
        applyPopoverHeightImmediately(clamped)
    }

    private func toggleResetCreditsDrawer(fullHeight: CGFloat) {
        fullDrawerHeight = fullHeight
        if baseCollapsedHeight == 0 {
            baseCollapsedHeight = max(80, currentPopoverHeight - clock.animatedDrawerHeight)
        }

        let targetExpanded = !clock.resetCreditsTargetExpanded
        clock.resetCreditsTargetExpanded = targetExpanded

        let startProgress = clock.resetCreditsProgress
        let endProgress: CGFloat = targetExpanded ? 1 : 0
        let remainingFraction = abs(Double(endProgress - startProgress))
        guard remainingFraction > 0.001 else { return }

        let duration = max(0.08, PopoverMotion.duration * remainingFraction)
        let startTime = CACurrentMediaTime()

        drawerAnimationTimer?.invalidate()
        isAnimatingDrawer = true

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let elapsed = CACurrentMediaTime() - startTime
                let rawT = min(1.0, elapsed / duration)
                let eased = CGFloat(PopoverMotion.easeOutCubic(rawT))
                let progress = startProgress + (endProgress - startProgress) * eased
                let drawerHeight = PopoverMotion.pixelAligned(self.fullDrawerHeight * progress)
                let targetPopoverHeight = self.baseCollapsedHeight + drawerHeight

                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.clock.resetCreditsProgress = progress
                self.clock.animatedDrawerHeight = drawerHeight
                self.applyPopoverHeightImmediately(targetPopoverHeight)
                CATransaction.commit()

                if rawT >= 1.0 {
                    timer.invalidate()
                    self.drawerAnimationTimer = nil
                    self.isAnimatingDrawer = false
                }
            }
        }
        drawerAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func applyPopoverHeightImmediately(_ height: CGFloat) {
        let clamped = max(80, PopoverMotion.pixelAligned(height))
        guard abs(clamped - currentPopoverHeight) > 0.25 else { return }
        currentPopoverHeight = clamped
        let targetSize = NSSize(width: PopoverMotion.width, height: clamped)
        let wasAnimating = popover.animates
        popover.animates = false
        popover.contentSize = targetSize
        popover.animates = wasAnimating
    }

    private func setDisplayMode(_ mode: StatusBarDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        mode.save()
        updateStatusView(force: true)
    }

    @objc private func updateStatusViewForEnvironmentChange() {
        updateStatusView(force: true)
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) == true) {
            showContextMenu(for: sender)
            return
        }
        togglePopover(relativeTo: sender)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            openPopover(relativeTo: button)
        }
    }

    private func openPopover(relativeTo button: NSStatusBarButton) {
        clock.now = Date()
        updateStatusView()
        if currentPopoverHeight == 0, let view = popover.contentViewController?.view {
            view.frame = NSRect(x: 0, y: 0, width: PopoverMotion.width, height: 10)
            view.layoutSubtreeIfNeeded()
            if currentPopoverHeight == 0 {
                let initialHeight = max(120, PopoverMotion.pixelAligned(view.fittingSize.height))
                baseCollapsedHeight = initialHeight
                applyPopoverHeightImmediately(initialHeight)
            }
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        startPopoverMonitors()
    }

    private func closePopover() {
        finishDrawerAnimationAtTarget()
        popover.performClose(nil)
        stopPopoverMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        finishDrawerAnimationAtTarget()
        stopPopoverMonitors()
    }

    private func finishDrawerAnimationAtTarget() {
        drawerAnimationTimer?.invalidate()
        drawerAnimationTimer = nil
        guard isAnimatingDrawer else { return }
        isAnimatingDrawer = false
        let endProgress: CGFloat = clock.resetCreditsTargetExpanded ? 1 : 0
        let drawerHeight = PopoverMotion.pixelAligned(fullDrawerHeight * endProgress)
        clock.resetCreditsProgress = endProgress
        clock.animatedDrawerHeight = drawerHeight
        applyPopoverHeightImmediately(baseCollapsedHeight + drawerHeight)
    }

    private func startPopoverMonitors() {
        stopPopoverMonitors()

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock.now = Date()
                self.updateStatusView()
            }
        }
        popoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopover()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePopover()
                return nil
            }
            return event
        }
    }

    private func stopPopoverMonitors() {
        popoverTimer?.invalidate()
        popoverTimer = nil
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        }
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        for mode in StatusBarDisplayMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectDisplayModeFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = mode == displayMode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        clock.now = Date()
        Task { await store.refresh() }
    }

    @objc private func selectDisplayModeFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = StatusBarDisplayMode(rawValue: raw) else { return }
        setDisplayMode(mode)
    }

    private func updateStatusView(force: Bool = false) {
        let now = Date()
        let groups = store.installedProviders.map { provider in
            switch provider {
            case .codex:
                return QuotaStatusPresentation.codexGroup(store.snapshot, at: now)
            case .grok:
                return QuotaStatusPresentation.grokGroup(store.grokSnapshot, at: now)
            case .agy:
                return QuotaStatusPresentation.agyGroup(store.agySnapshot, at: now)
            }
        }

        let renderState = StatusRenderState(mode: displayMode, groups: groups)
        statusItem.isVisible = !groups.isEmpty
        guard !groups.isEmpty else {
            lastRenderState = renderState
            return
        }

        guard force || renderState != lastRenderState else {
            return
        }

        let image = QuotaStatusImageRenderer.render(groups: renderState.groups, mode: renderState.mode)
        statusItem.button?.image = image
        statusItem.button?.toolTip = nil
        statusItem.length = image.size.width
        statusOverlay.mode = renderState.mode
        statusOverlay.groups = renderState.groups
        lastRenderState = renderState
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
