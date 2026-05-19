import SwiftUI

struct ActionFeedback: Equatable {
    enum Kind {
        case success
        case error
        case info

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .error: "exclamationmark.triangle.fill"
            case .info: "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .green
            case .error: .red
            case .info: .accentColor
            }
        }
    }

    let kind: Kind
    let message: String
}

struct ActionFeedbackView: View {
    let feedback: ActionFeedback

    var body: some View {
        Label {
            Text(feedback.message)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: feedback.kind.symbol)
        }
        .font(.callout)
        .foregroundStyle(feedback.kind.tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(feedback.kind.tint.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
