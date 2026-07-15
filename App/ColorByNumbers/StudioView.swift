import CBNKit
import SwiftUI

/// The kid's library — DESIGN.md's "Studio": a grid of coloring pages, tap
/// one to start coloring. Nothing here is destructive and nothing here is a
/// setting; deletion, renaming, import, and export all live in the Workshop
/// (M4), behind its own parental gate. The Studio's safety comes from what
/// simply isn't reachable from it, not from confirmation dialogs.
struct StudioView: View {
    let library: CBNLibrary

    @State private var items: [CBNLibraryItem] = []
    /// Outline thumbnails, rendered once per item per app run and kept here
    /// — TemplateRenderer is CPU rasterization, not something to redo on
    /// every body evaluation.
    @State private var thumbnails: [String: Image] = [:]

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 28)]

    var body: some View {
        NavigationStack {
            ZStack {
                DeskStyle.deskColor.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Color by Numbers")
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .foregroundStyle(DeskStyle.inkColor)
                            .padding(.top, 8)

                        LazyVGrid(columns: columns, spacing: 28) {
                            ForEach(items) { item in
                                NavigationLink {
                                    CanvasView(library: library, item: item)
                                } label: {
                                    TemplateCard(item: item, thumbnail: thumbnails[item.id])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            loadItems()
        }
    }

    private func loadItems() {
        guard let loaded = try? library.items() else { return }
        items = loaded
        for item in loaded where thumbnails[item.id] == nil {
            renderThumbnail(for: item)
        }
    }

    private func renderThumbnail(for item: CBNLibraryItem) {
        let targetWidth = 360.0
        let scale = targetWidth / max(item.template.size.width, 1)
        guard let cgImage = TemplateRenderer.render(item.template, mode: .outline, scale: scale) else {
            return
        }
        thumbnails[item.id] = Image(decorative: cgImage, scale: 1)
    }
}

/// One library card: a white "page" with a soft shadow holding the
/// template's outline thumbnail, titled beneath in rounded type.
private struct TemplateCard: View {
    let item: CBNLibraryItem
    let thumbnail: Image?

    private var aspectRatio: Double {
        item.template.size.height > 0 ? item.template.size.width / item.template.size.height : 1
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: DeskStyle.cardCornerRadius, style: .continuous)
                    .fill(Color.white)
                    .shadow(
                        color: DeskStyle.shadowColor,
                        radius: DeskStyle.shadowRadius,
                        x: 0,
                        y: DeskStyle.shadowYOffset
                    )

                if let thumbnail {
                    thumbnail
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)

            Text(item.template.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(DeskStyle.inkColor)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    StudioView(library: previewLibrary(seeding: [.previewSample]))
}
