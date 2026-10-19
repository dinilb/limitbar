import LimitBarDomain
import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let store = UsageStore()
    private var cancellables = Set<AnyCancellable>()
    private var countdownTimer: Timer?
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusBarRenderer.placeholderImage()
        statusItem.button?.toolTip = MenuBarStatus.loadingColumn.detail
        statusItem.button?.setAccessibilityLabel(MenuBarStatus.loadingColumn.detail)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.behavior = .transient
        let content = NSHostingController(
            rootView: UsagePopoverView(store: store) { NSApp.terminate(nil) }
        )
        // NSPopover positions itself from its content's `preferredContentSize`,
        // which an NSHostingController leaves at zero until SwiftUI has laid
        // out. Without this the popover anchors against a 0x0 box, works out
        // where a nothing-sized window should go, and only then grows to fit —
        // which is why it opened nowhere near the status item. `sizingOptions`
        // keeps the two in step as the content changes height (an error
        // callout appearing, a provider coming or going); the explicit size
        // covers the very first show, before any layout pass has run.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.contentSize = content.view.fittingSize
        self.popover = popover

        // A CLI failure is as much a status change as a new document — before the
        // first success it is the *only* thing the bar has to report — so both
        // publishers drive the redraw.
        store.$document
            .combineLatest(store.$lastError)
            .receive(on: RunLoop.main)
            .sink { [weak self] document, error in self?.render(document, error: error) }
            .store(in: &cancellables)

        // Redraw once a minute so the reset countdown stays honest between polls.
        let countdown = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.render(self.store.document, error: self.store.lastError)
            }
        }
        countdown.tolerance = 10
        RunLoop.main.add(countdown, forMode: .common)
        countdownTimer = countdown

        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        countdownTimer?.invalidate()
        store.stop()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    private func render(_ document: UsageDocument, error: String?) {
        // Tooltip and accessibility label come from the same columns the image
        // is drawn from, so the three can never disagree about the five-hour
        // line.
        statusItem?.button?.image = StatusBarRenderer.image(for: document, error: error)
        statusItem?.button?.toolTip = StatusBarRenderer.tooltip(for: document, error: error)
        statusItem?.button?.setAccessibilityLabel(
            MenuBarStatus.accessibilityLabel(for: document, error: error)
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            // A right-click is too easy to hit by accident to justify launching
            // `claude`; it refreshes within the usual throttle.
            store.refresh(force: true)
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshIfOlder(than: 120)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
