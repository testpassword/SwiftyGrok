import SwiftUI
import AppKit
import MapKit
import GrokCore

@MainActor struct PlaceCardsView: View {
    let gallery: PlaceGallery
    let media: MessageMediaLoader?
    @State private var selected: PlaceCard?

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 12) {
                ForEach(gallery.places) { place in
                    Button { selected = place } label: {
                        ZStack(alignment: .bottomLeading) {
                            PlacePhotoView(photo: place.photos.first, media: media)
                                .frame(width: 224, height: 274).clipped()
                            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(place.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                                HStack(spacing: 5) {
                                    if let rating = place.rating {
                                        Image(appSymbol: "star.fill").font(.system(size: 11))
                                        Text(rating.formatted(.number.precision(.fractionLength(0...1))))
                                    }
                                    if let open = place.isOpen {
                                        if place.rating != nil { Text("·") }
                                        Text(L10n.text(open ? "Open now" : "Closed now"))
                                    }
                                }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                            }.foregroundStyle(.white).padding(14)
                        }
                        .frame(width: 224, height: 274)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(place.name)
                    .help(L10n.text("View place details"))
                }
            }.padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ChatHorizontalScroll())
        .sheet(item: $selected) { place in PlaceDetailsView(place: place, media: media) }
    }
}

@MainActor private struct PlaceDetailsView: View {
    let place: PlaceCard
    let media: MessageMediaLoader?
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = AppearanceSettings.shared
    @State private var photoIndex = 0

    private var photo: PlacePhoto? { place.photos.indices.contains(photoIndex) ? place.photos[photoIndex] : nil }
    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var phoneURL: URL? {
        guard let phone = place.phone else { return nil }
        let digits = phone.filter { "0123456789".contains($0) }
        guard !digits.isEmpty else { return nil }
        let prefix = phone.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") ? "+" : ""
        return URL(string: "tel:\(prefix)\(digits)")
    }

    private var photoHeader: some View {
        ZStack(alignment: .bottom) {
            PlacePhotoView(photo: photo, media: media)
            LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 14) {
                Text(place.name)
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .multilineTextAlignment(.center).lineLimit(3)
                    .shadow(color: .black.opacity(0.25), radius: 4)
                if let coordinate {
                    Button { directions(to: coordinate) } label: {
                        Label(L10n.text("Directions"), appSymbol: "location")
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .controlSize(.large).buttonBorderShape(.capsule)
                    .modifier(PlaceGlassButtons())
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20).padding(.bottom, 22)
        }
        .frame(height: place.photos.isEmpty ? 220 : 300)
        .clipped().clipShape(RoundedRectangle(cornerRadius: 16))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    photoHeader
                    if !place.photos.isEmpty {
                        if place.photos.count > 1 {
                            ScrollView(.horizontal) {
                                HStack(spacing: 8) {
                                    ForEach(place.photos.indices, id: \.self) { index in
                                        Button { photoIndex = index } label: {
                                            PlacePhotoView(photo: place.photos[index], media: media, credit: false)
                                                .frame(width: 72, height: 52).clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(index == photoIndex ? Color.accentColor : .clear, lineWidth: 2))
                                        }.buttonStyle(.plain).accessibilityLabel(L10n.format("Photo %@", (index + 1).formatted()))
                                    }
                                }
                            }.scrollIndicators(.hidden)
                        }
                    }
                    if let rating = place.rating {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text(rating.formatted(.number.precision(.fractionLength(0...1)))).fontWeight(.medium)
                                if let count = place.reviewCount { Text(L10n.format("Reviews: %@", count.formatted())).foregroundStyle(.secondary) }
                            }
                        } label: { Label(L10n.text("Rating"), appSymbol: "star") }
                    }
                    if place.isOpen != nil || !place.hours.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(place.hours.enumerated()), id: \.offset) { _, hours in Text(hours) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8).textSelection(.enabled)
                        } label: {
                            HStack {
                                Label(L10n.text("Hours"), appSymbol: "clock")
                                Spacer()
                                if let open = place.isOpen { Text(L10n.text(open ? "Open now" : "Closed now")).foregroundStyle(open ? Color.green : Color.secondary) }
                            }
                        }
                        .disclosureGroupStyle(PlaceHoursDisclosureStyle())
                        .disabled(place.hours.isEmpty)
                    }
                    if let coordinate {
                        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))) {
                            Marker(place.name, coordinate: coordinate)
                        }
                        .mapControls { MapZoomStepper() }
                        .frame(height: 200).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    if let address = place.address {
                        LabeledContent {
                            Text(address).multilineTextAlignment(.trailing).textSelection(.enabled)
                        } label: { Label(L10n.text("Address"), appSymbol: "mappin.and.ellipse") }
                    }
                    if let phone = place.phone {
                        LabeledContent {
                            if let url = phoneURL { Link(phone, destination: url) }
                            else { Text(phone).textSelection(.enabled) }
                        } label: { Label(L10n.text("Phone"), appSymbol: "phone") }
                    }
                    HStack(spacing: 12) {
                        if let url = place.website { Link(L10n.text("Website"), destination: url).modifier(PlaceGlassButtons()) }
                        if let url = place.mapsURL {
                            Link(destination: url) { Label(L10n.text("Open in browser"), appSymbol: "safari") }
                                .modifier(PlaceGlassButtons())
                        }
                    }.controlSize(.large)
                }.font(.system(size: 14)).padding(20)
            }
        }
        .frame(width: 560, height: 660)
        .background(appearance.theme.settingsBackground)
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: { Image(appSymbol: "xmark").frame(width: 20, height: 20) }
                .buttonBorderShape(.circle).modifier(PlaceGlassButtons())
                .keyboardShortcut(.cancelAction)
                .help(L10n.text("Close")).accessibilityLabel(L10n.text("Close"))
                .padding(32)
        }
        .modifier(AppAppearance())
    }

    private func directions(to coordinate: CLLocationCoordinate2D) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
}

@MainActor private struct PlaceHoursDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(appSymbol: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(L10n.text(configuration.isExpanded ? "Expanded" : "Collapsed"))
            if configuration.isExpanded { configuration.content }
        }
    }
}

@MainActor private struct PlacePhotoView: View {
    let photo: PlacePhoto?
    let media: MessageMediaLoader?
    var credit = true
    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.primary.opacity(0.08)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    Image(appSymbol: "mappin.and.ellipse").font(.system(size: 32))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if credit, let authors = photo?.authors, !authors.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(authors.indices, id: \.self) { index in
                            if let url = authors[index].url { Link(authors[index].name, destination: url) }
                            else { Text(authors[index].name) }
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule()).padding(8)
                }
            }
        }
        .task(id: photo?.url) {
            image = nil
            guard let url = photo?.url, let media else { return }
            do {
                let data = try await media.data(for: url)
                try Task.checkCancellation()
                guard let loaded = NSImage(data: data), loaded.size.width > 0, loaded.size.height > 0 else { return }
                image = loaded
            } catch { }
        }
    }
}

private struct PlaceGlassButtons: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
