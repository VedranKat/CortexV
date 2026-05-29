import Foundation

enum NavigationSection: String, CaseIterable, Identifiable {
    case sessions
    case changes
    case agents
    case workspaces
    case releaseNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: "Start Session"
        case .changes: "Changes"
        case .agents: "Agents"
        case .workspaces: "Workspaces"
        case .releaseNotes: "Release Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: "plus.bubble"
        case .changes: "doc.text.magnifyingglass"
        case .agents: "person.crop.circle.badge.checkmark"
        case .workspaces: "folder"
        case .releaseNotes: "doc.text"
        }
    }

    var showsCount: Bool {
        switch self {
        case .sessions, .changes, .agents, .workspaces:
            true
        case .releaseNotes:
            false
        }
    }
}
