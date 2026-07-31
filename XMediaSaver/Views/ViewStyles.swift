import SwiftUI

extension View {
    func saverCard() -> some View {
        padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func compactBackButton() -> some View {
        modifier(CompactBackButtonModifier())
    }

    func edgeSwipeBack() -> some View {
        modifier(EdgeSwipeBackModifier())
    }
}

private struct CompactBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .accessibilityLabel("Back")
                }
            }
    }
}

private struct EdgeSwipeBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(
                minimumDistance: 12,
                coordinateSpace: .global
            )
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = abs(value.translation.height)
                let predicted = value.predictedEndTranslation.width
                guard value.startLocation.x <= 24,
                      horizontal > 0,
                      horizontal > vertical * 1.2,
                      horizontal >= 72 || predicted >= 120
                else {
                    return
                }
                dismiss()
            }
        )
    }
}
