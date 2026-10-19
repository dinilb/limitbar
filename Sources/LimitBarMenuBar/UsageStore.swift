import LimitBarDomain
import LimitBarProviders
import AppKit
import Combine
import Foundation
import WidgetKit

/// Owns the refresh loop and publishes the latest document to the UI.
@MainActor
final class UsageStore: ObservableObject {
    /// Never poll faster than this. The Claude usage endpoint is known to
    /// rate-limit aggressively (see RESEARCH.md §5.3), and the CLI's own cache
    /// is what makes a shorter interval pointless anyway.
    static let minimumInterval: TimeInterval = 60
    static let defaultInterval: TimeInterval = 300

    @Published private(set) var document: UsageDocument = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshedAt: Date?

    private var timer: Timer?
    private let service: UsageService
    private let interval: TimeInterval

    @Published private(set) var commandLineToolStatus = CommandLineToolInstaller.status()

    init(service: UsageService = UsageService(), interval: TimeInterval = UsageStore.defaultInterval) {
        self.service = service
        self.interval = max(UsageStore.minimumInterval, interval)
    }

    func start() {
        refresh(force: false)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(force: false) }
        }
        // Some jitter so several launches on one machine do not sync up.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // The timer does not fire while the Mac sleeps, so a lid that was closed
        // for hours would otherwise show hours-old numbers until the next tick.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give Wi-Fi a moment to come back before going upstream.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                self?.refresh(force: true)
            }
        }
    }

    /// Opening the popover is a request to look at the numbers, so make sure they
    /// are recent without hammering the endpoint on every click.
    func refreshIfOlder(than age: TimeInterval) {
        guard let lastRefreshedAt, Date().timeIntervalSince(lastRefreshedAt) < age else {
            refresh(force: true)
            return
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// - Parameters:
    ///   - force: ignore cache freshness and go upstream.
    ///   - userInitiated: a person asked for this reading, so launching `claude` to
    ///     renew an expired login is not throttled. Nothing ever shows a dialog.
    func refresh(force: Bool = true, userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true

        let service = self.service
        Task.detached(priority: .utility) {
            let document = await service.collect(UsageRequest(refresh: force, userInitiated: userInitiated))
            await MainActor.run { [weak self] in
                self?.apply(.success(document))
            }
        }
    }

    func installCommandLineTool() {
        do {
            try CommandLineToolInstaller.installInteractively()
            commandLineToolStatus = CommandLineToolInstaller.status()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeCommandLineTool() {
        do {
            try CommandLineToolInstaller.remove()
            commandLineToolStatus = CommandLineToolInstaller.status()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(_ result: Result<UsageDocument, Error>) {
        isRefreshing = false
        switch result {
        case .success(let document):
            self.document = document
            lastError = nil
            lastRefreshedAt = Date()
            publishToWidget(document)
        case .failure(let error):
            // Keep the previous document on screen; a transient CLI failure
            // should not blank the menu bar.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastRefreshedAt = Date()
        }
    }

    private func publishToWidget(_ document: UsageDocument) {
        let snapshot = WidgetSnapshot(document: document)
        snapshot.writeForWidget()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
