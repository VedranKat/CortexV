import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            contentView
                .navigationTitle(appModel.selectedSection?.title ?? "Cortex V")
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup {
                if appModel.selectedSection == .sessions, appModel.selectedWorkspaceID != nil {
                    Button {
                        appModel.prepareNewSession()
                    } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch appModel.selectedSection ?? .sessions {
        case .sessions:
            SessionsView()
        case .agents:
            AgentsView()
        case .workspaces:
            WorkspacesView()
        case .releaseNotes:
            ReleaseNotesView()
        }
    }
}
