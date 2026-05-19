import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.headline)

            DetailRow(title: "Selected", value: appModel.selectedSection?.title ?? "None")
            DetailRow(title: "Database", value: "~/Library/Application Support/Cortex V/data/CortexV.sqlite")
            DetailRow(title: "Tool Limit", value: "8 rounds")
            DetailRow(title: "Read Limit", value: "512 KB")
            DetailRow(title: "Content Cap", value: "24,000 chars")

            Divider()

            Text("This column will show selected session metadata, tool activity, and review context as the vertical slice lands.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
        }
    }
}
