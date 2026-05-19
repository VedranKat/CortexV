import Foundation

struct DashboardSnapshot {
    var sessionsCount: Int
    var agentsCount: Int
    var workspacesCount: Int
    var pendingChangesCount: Int

    static let empty = DashboardSnapshot(
        sessionsCount: 0,
        agentsCount: 0,
        workspacesCount: 0,
        pendingChangesCount: 0
    )
}
