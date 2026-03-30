import Observation
import SwiftUI

struct ContentView: View {
    @State private var store = PromptDocumentStore()

    var body: some View {
        ZStack {
            AppBackground()

            GeometryReader { geometry in
                let editorContentWidth = max(0, geometry.size.width - LayoutMetrics.screenPadding * 2)
                let metrics = LayoutMetrics(editorContentWidth: editorContentWidth)

                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
                            PromptComposer(store: store, metrics: metrics)
                        }
                        .frame(
                            width: max(0, geometry.size.width - (metrics.screenPadding * 2)),
                            alignment: .leading
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(metrics.screenPadding)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle("Spellline")
                    .toolbarBackground(.hidden, for: .navigationBar)
                }
            }
        }
    }
}

// MARK: - Prompt Composer

private struct PromptComposer: View {
    @Bindable var store: PromptDocumentStore
    let metrics: LayoutMetrics

    private var tokenStatusLine: String {
        let count = store.document.tokens.count
        if count == 0 {
            return "Typing turns into smart controls automatically"
        }
        return count == 1 ? "1 smart control" : "\(count) smart controls"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label("Draft Prompt", systemImage: "character.cursor.ibeam")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(tokenStatusLine)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(alignment: .leading, spacing: 10) {
                InlinePromptEditor(store: store, metrics: metrics)
                    .frame(minHeight: metrics.editorMinHeight)

                Text("Matched parts morph into real inline controls. Use minus and plus, sliders, menus, toggles, or edit the sentence like normal text.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, metrics.controlPadding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Light") {
    ContentView()
        .frame(width: 393, height: 852)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    ContentView()
        .frame(width: 393, height: 852)
        .preferredColorScheme(.dark)
}
