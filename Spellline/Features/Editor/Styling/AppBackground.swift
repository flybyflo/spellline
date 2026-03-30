import SwiftUI

// MARK: - Background

struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark ? Self.darkGradientColors : Self.lightGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private static let lightGradientColors: [Color] = [
        Color(red: 0.97, green: 0.94, blue: 0.89),
        Color(red: 0.89, green: 0.92, blue: 0.98)
    ]

    /// Deep warm-to-cool gradient matching the light palette’s direction, tuned for legibility with light text.
    private static let darkGradientColors: [Color] = [
        Color(red: 0.12, green: 0.11, blue: 0.13),
        Color(red: 0.07, green: 0.09, blue: 0.14)
    ]
}
