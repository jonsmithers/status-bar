import SwiftUI
import AppKit

@main
struct StatusBarMenuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = JobsObservable()

    var body: some Scene {
        MenuBarExtra {
            JobsMenuView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: JobsObservable

    var body: some View {
        if store.runningCount > 0 {
            Image(systemName: "circle.dotted")
            Text("\(store.runningCount)")
        } else if store.failedCount > 0 {
            Image(systemName: "exclamationmark.circle.fill")
        } else if store.completedCount > 0 {
            Image(systemName: "checkmark.circle")
        } else {
            Image(systemName: "circle.dashed")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock; we live only in the menu bar.
        NSApp.setActivationPolicy(.accessory)
    }
}
