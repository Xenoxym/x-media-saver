import SwiftUI

extension View {
    func saverCard() -> some View {
        padding()
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    func compactBackButton() -> some View {
        modifier(CompactBackButtonModifier(action: nil))
    }

    func compactBackButton(
        action: @escaping () -> Void
    ) -> some View {
        modifier(CompactBackButtonModifier(action: action))
    }

    func edgeSwipeBack() -> some View {
        modifier(EdgeSwipeBackModifier(action: nil))
    }

    func edgeSwipeBack(
        action: @escaping () -> Void
    ) -> some View {
        modifier(EdgeSwipeBackModifier(action: action))
    }
}

private struct CompactBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if let action {
                            action()
                        } else {
                            dismiss()
                        }
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
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            Color.clear
                .frame(width: 24)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(
                        minimumDistance: 12,
                        coordinateSpace: .global
                    )
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = abs(value.translation.height)
                        let predicted =
                            value.predictedEndTranslation.width
                        guard horizontal > 0,
                              horizontal > vertical * 1.2,
                              horizontal >= 72 || predicted >= 120
                        else {
                            return
                        }
                        if let action {
                            action()
                        } else {
                            dismiss()
                        }
                    }
                )
                .ignoresSafeArea(edges: .vertical)
        }
    }
}
