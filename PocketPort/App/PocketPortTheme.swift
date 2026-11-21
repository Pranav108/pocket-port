import SwiftUI

struct PocketPortCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Color(uiColor: .systemGroupedBackground)
            .overlay(alignment: .topTrailing) {
                if !reduceTransparency {
                    RadialGradient(
                        colors: [.teal.opacity(colorScheme == .dark ? 0.20 : 0.12), .clear],
                        center: .topTrailing,
                        startRadius: 8,
                        endRadius: 360
                    )
                    .frame(height: 380)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func pocketPortGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func pocketPortActionStyle(prominent: Bool = false) -> some View {
        let action = controlSize(.large).buttonBorderShape(.capsule)
        if #available(iOS 26.0, *) {
            if prominent {
                action.buttonStyle(.glassProminent)
            } else {
                action.buttonStyle(.glass)
            }
        } else if prominent {
            action.buttonStyle(.borderedProminent)
        } else {
            action.buttonStyle(.bordered)
        }
    }
}
