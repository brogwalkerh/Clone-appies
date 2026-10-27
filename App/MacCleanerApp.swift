import AppIntents
import SwiftUI
import DesignSystem

/// App entry point. One main window (minimum 1200×800), a Settings scene, and
/// text-only menus with ⌘1–⌘9 module shortcuts (PLAN.md §4).
@main
struct MacCleanerApp: App {
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        // Intents and Siri AI reach the UI through this shared service object.
        AppServices.shared.appState = state
        // Publishes the App Shortcuts phrases so Siri AI / Spotlight can discover them.
        MacCleanerShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup("Mac Cleaner") {
            RootView()
                .environment(appState)
                .frame(minWidth: Metrics.minimumWindowSize.width,
                       minHeight: Metrics.minimumWindowSize.height)
                // `maccleaner://smart-care`, `cleanup?scanner=`, `performance?task=`
                // from the menu bar agent, Spotlight or the CLI (CFBundleURLTypes in Info.plist).
                .onOpenURL { url in
                    appState.open(url)
                }
        }
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentMinSize)
        .commands {
            ModuleCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// "Go" menu with one text-only item per module. Menus carry no icons on
/// macOS 27, so these are plain `Button` titles.
struct ModuleCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(SidebarItem.allCases.filter { $0.shortcutDigit != nil }) { item in
                Button(item.title) {
                    appState.select(item)
                }
                .keyboardShortcut(KeyEquivalent(item.shortcutDigit ?? "0"), modifiers: .command)
            }
            Divider()
            Button("My Activity") { appState.select(.myActivity) }
            Button("Menu") { appState.select(.menuApp) }
        }

        CommandGroup(replacing: .newItem) {
            // Single-window app: no File › New.
        }

        CommandGroup(after: .toolbar) {
            Button("Run Cleanup Scan") {
                appState.select(.cleanup)
                appState.runCleanup()
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }
}
