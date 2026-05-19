import SwiftUI

@main
struct CortexVApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appModel)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    appModel.prepareNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Send Message") {
                    appModel.requestSend()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }

            CommandGroup(after: .appInfo) {
                Button("Release Notes") {
                    appModel.selectedSection = .releaseNotes
                }
            }
        }
    }
}
