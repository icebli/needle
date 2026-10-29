import SwiftUI

extension View {
    @ViewBuilder
    func needleGlassSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func needlePrimaryAction() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
