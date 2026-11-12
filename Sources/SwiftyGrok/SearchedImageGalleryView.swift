import SwiftUI
import GrokCore

@MainActor struct SearchedImageGalleryView: View {
    let gallery: SearchedImageGallery
    let media: MessageMediaLoader?
    @State private var selectedID: String?
    @State private var width: CGFloat = 600

    private var height: CGFloat { min(420, max(180, width * 0.75)) }
    private var index: Int { gallery.images.firstIndex { $0.id == selectedID } ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(gallery.images) { image in
                        MessageImage(url: image.url, name: image.title, media: media, presentation: .gallery,
                                     fallbackURL: image.thumbnailURL, maximumHeight: height,
                                     source: image.sourceURL.map { MessageSource(id: image.id, title: image.source ?? $0.host ?? image.title, url: $0) })
                            .frame(width: width, height: height)
                            .id(image.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $selectedID, anchor: .leading)
            .frame(height: height)
            .modifier(ChatHorizontalScroll())
            if gallery.images.count > 1 {
                HStack(spacing: 2) {
                    ForEach(Array(gallery.images.enumerated()), id: \.element.id) { position, image in
                        Button { select(position) } label: {
                            Circle().fill(position == index ? Color.primary : .secondary.opacity(0.4))
                                .frame(width: 6, height: 6).frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.format("Image %@ of %@", String(position + 1), String(gallery.images.count)))
                        .accessibilityAddTraits(position == index ? .isSelected : [])
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .onChange(of: gallery.images.map(\.id), initial: true) { _, ids in
            if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
        }
    }

    private func select(_ index: Int) {
        guard gallery.images.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { selectedID = gallery.images[index].id }
    }
}
