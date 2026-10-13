import AppKit
import SwiftUI
import CleanerCore
import DesignSystem

/// Protection › Privacy: browser history, cookies and caches, recent items,
/// Wi-Fi networks and chat caches through the shared `FindingsList` over
/// `AppState.privacyModel` (`PrivacyScanners.all()`), with a banner that
/// quits running browsers first so their databases are not locked.
struct PrivacyTab: View {
    let model: ScanViewModel
    @Binding var expandedGroups: Set<String>
    let fullDiskAccessDenied: Bool
    let onScan: @MainActor () -> Void

    @State private var runningBrowsers: [SupportedBrowser] = []
    @State private var confirmQuit = false

    var body: some View {
        VStack(spacing: 0) {
            browserBanner
            content
        }
        .task {
            // Re-check every few seconds so the banner clears once browsers quit.
            while !Task.isCancelled {
                runningBrowsers = SupportedBrowser.running()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Quit \(runningBrowsers.map(\.name).formatted(.list(type: .and)))?",
                            isPresented: $confirmQuit,
                            titleVisibility: .visible) {
            Button("Quit Browsers") { quitBrowsers() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each browser is asked to quit normally, so it can offer to save open work. Tabs are restored the next time it opens.")
        }
    }

    // MARK: Banner

    private var browserBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: runningBrowsers.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(runningBrowsers.isEmpty ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(runningBrowsers.isEmpty
                     ? "No browsers are running."
                     : "\(runningBrowsers.map(\.name).formatted(.list(type: .and))) \(runningBrowsers.count == 1 ? "is" : "are") running.")
                    .font(.callout)
                Text("Quit browsers before removing history or cookies: open browsers keep those databases locked and recreate them on exit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !runningBrowsers.isEmpty {
                Button("Quit Browsers") { confirmQuit = true }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle where fullDiskAccessDenied:
            EmptyState.needsPermission(
                "Full Disk Access",
                message: "Safari history, cookies and other browsers' profiles stay hidden without it. You can still scan what is visible.") {
                PermissionChecker.openSystemSettings(for: .fullDiskAccess)
            }

        case .idle:
            EmptyState(title: "Ready to Scan",
                       message: "Finds browsing history, cookies and caches for Safari, Chrome-based browsers and Firefox, recent-items lists, QuickLook thumbnails, Wi-Fi networks and chat app caches. Logins and bookmarks are never touched.",
                       style: .symbol("hand.raised"))

        case .scanning where model.findings.isEmpty:
            EmptyState.scanning("Scanning for traces…",
                                message: model.statusLine,
                                cancel: { model.cancel() })

        case .finished where model.findings.isEmpty, .cancelled where model.findings.isEmpty:
            EmptyState.nothingFound(
                model.phase == .cancelled ? "Scan Stopped" : "Nothing to Remove",
                message: model.phase == .cancelled
                    ? "The scan was stopped before it finished."
                    : "No browsing history, cookies or app caches were found in the supported locations.",
                actionTitle: "Scan Again") {
                onScan()
            }

        default:
            FindingsList(model: model, expandedGroups: $expandedGroups)
        }
    }

    // MARK: Browsers

    private func quitBrowsers() {
        for browser in runningBrowsers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID) {
                // Graceful quit (⌘Q equivalent). Force quit is deliberately not offered here.
                app.terminate()
            }
        }
        runningBrowsers = SupportedBrowser.running()
    }
}

/// Browsers whose data the privacy scanners touch (PLAN.md §3.3).
struct SupportedBrowser: Identifiable, Hashable, Sendable {
    let name: String
    let bundleID: String

    var id: String { bundleID }

    static let supported: [SupportedBrowser] = [
        SupportedBrowser(name: "Safari", bundleID: "com.apple.Safari"),
        SupportedBrowser(name: "Google Chrome", bundleID: "com.google.Chrome"),
        SupportedBrowser(name: "Firefox", bundleID: "org.mozilla.firefox"),
        SupportedBrowser(name: "Arc", bundleID: "company.thebrowser.Browser"),
        SupportedBrowser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac")
    ]

    @MainActor
    static func running() -> [SupportedBrowser] {
        supported.filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty }
    }
}

#Preview {
    PrivacyTab(model: AppState().privacyModel,
               expandedGroups: .constant([]),
               fullDiskAccessDenied: false,
               onScan: {})
        .frame(width: 1000, height: 700)
}
