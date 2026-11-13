import SwiftUI
import GrokCore

@MainActor struct UnavailableResponseCardView: View {
    let card: UnavailableResponseCard

    private var title: String {
        switch card.reason {
        case .unsupported: return L10n.text("This card type is not supported yet")
        case .invalidData: return L10n.text("Could not display this card")
        case .missingData: return L10n.text("Card data was not received")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, appSymbol: "rectangle.stack.badge.exclamationmark")
                .font(.callout.weight(.medium)).foregroundStyle(.secondary)
            Text(verbatim: card.kind).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            DisclosureGroup(L10n.text("Raw card data")) {
                VStack(alignment: .trailing, spacing: 8) {
                    Button { ClipboardFeedback.shared.copy(card.rawData) } label: {
                        Label(L10n.text("Copy code"), appSymbol: "doc.on.doc")
                    }.buttonStyle(.borderless)
                    ScrollView([.horizontal, .vertical]) {
                        Text(verbatim: card.rawData).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }.frame(maxHeight: 220).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }.padding(.top, 8)
            }
            .font(.callout).disclosureGroupStyle(ClickableDisclosureStyle())
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.12)))
    }
}

@MainActor struct WeatherCardView: View {
    let card: WeatherCard
    @State private var scale: WeatherCard.TemperatureScale

    init(card: WeatherCard) {
        self.card = card
        _scale = State(initialValue: card.initialScale)
    }

    private var timezone: TimeZone { card.timezone.flatMap(TimeZone.init(identifier:)) ?? .current }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Text(card.location).font(.headline).textSelection(.enabled)
                Spacer(minLength: 8)
                Picker(L10n.text("Temperature unit"), selection: $scale) {
                    Text("°F").tag(WeatherCard.TemperatureScale.fahrenheit)
                    Text("°C").tag(WeatherCard.TemperatureScale.celsius)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 100)
            }
            if let current = card.current {
                HStack(spacing: 16) {
                    weatherIcon(current.condition, daylight: current.isDaylight, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(temperature(current.temperatureCelsius)).font(.system(size: 32, weight: .medium)).monospacedDigit()
                        Text(current.condition.localizedName).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    if let feelsLike = current.feelsLikeCelsius { metric(temperature(feelsLike), label: "Feels like") }
                    if let wind = current.windKilometersPerHour {
                        metric(L10n.format("%@ km/h", wind.formatted(.number.precision(.fractionLength(0)))), label: "Wind")
                    }
                    if let humidity = current.humidityPercent {
                        metric(humidity.formatted(.number.precision(.fractionLength(0))) + " %", label: "Humidity")
                    }
                }
            }
            if !card.hours.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 26) {
                        ForEach(card.hours.indices, id: \.self) { index in
                            let hour = card.hours[index]
                            VStack(spacing: 16) {
                                Text(hour.date.map(hourLabel) ?? "—").foregroundStyle(.secondary)
                                weatherIcon(hour.condition, daylight: hour.isDaylight, size: 24)
                                Text(temperature(hour.temperatureCelsius)).fontWeight(.semibold).monospacedDigit()
                            }
                            .frame(minWidth: 48)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel([hour.date.map(hourLabel) ?? "", hour.condition.localizedName, temperature(hour.temperatureCelsius)].joined(separator: ", "))
                        }
                    }.padding(.vertical, 4)
                }.scrollIndicators(.hidden)
            }
            if !card.days.isEmpty {
                DisclosureGroup(L10n.text("Daily forecast")) {
                    VStack(spacing: 12) {
                        ForEach(card.days.indices, id: \.self) { index in
                            let day = card.days[index]
                            HStack(spacing: 16) {
                                Text(formatted(day.date, .dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                Spacer(minLength: 8)
                                weatherIcon(day.condition, size: 18)
                                Text(temperature(day.lowCelsius)).foregroundStyle(.secondary).monospacedDigit().frame(width: 42, alignment: .trailing)
                                Text(temperature(day.highCelsius)).monospacedDigit().frame(width: 42, alignment: .trailing)
                            }.accessibilityElement(children: .combine)
                        }
                    }.padding(.top, 12)
                }.disclosureGroupStyle(ClickableDisclosureStyle())
            }
            if let asOf = card.current?.date {
                HStack {
                    Text(L10n.format("Weather as of %@", formatted(asOf, .dateTime.day().month().hour().minute())))
                    Spacer(minLength: 0)
                    if let url = card.attributionURL { Link(L10n.text("Source"), destination: url) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: 620, alignment: .leading)
        .modifier(ResponseCardBackground())
        .padding(.vertical, 6)
    }

    private func temperature(_ celsius: Double) -> String {
        let rounded = scale.temperature(fromCelsius: celsius).rounded()
        return (rounded == 0 ? 0 : rounded).formatted(.number.precision(.fractionLength(0))) + "°"
    }

    private func hourLabel(_ date: Date) -> String {
        if let asOf = card.current?.date, abs(date.timeIntervalSince(asOf)) < 3600, date <= asOf {
            return L10n.text("Now")
        }
        return formatted(date, .dateTime.hour(.defaultDigits(amPM: .omitted)))
    }

    private func formatted(_ date: Date, _ style: Date.FormatStyle) -> String {
        var style = style
        style.timeZone = timezone
        return date.formatted(style)
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(spacing: 6) {
            Text(value).font(.system(size: 18, weight: .medium)).monospacedDigit()
            Text(L10n.text(label)).font(.callout).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }

    private func weatherIcon(_ condition: WeatherCondition, daylight: Bool = true, size: CGFloat) -> some View {
        Image(appSymbol: condition.symbol(isDaylight: daylight))
            .symbolRenderingMode(.multicolor).font(.system(size: size))
            .frame(width: size * 1.5, height: size * 1.2)
            .accessibilityLabel(condition.localizedName)
    }
}

private struct ResponseCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.12)))
    }
}

@MainActor struct SportsStandingsCardView: View {
    let card: SportsStandingsCard
    @State private var selectedTableID: Int
    @State private var showAll = false

    init(card: SportsStandingsCard) {
        self.card = card
        _selectedTableID = State(initialValue: card.tables.first?.id ?? 0)
    }

    private var table: SportsStandingsCard.Table? { card.tables.first { $0.id == selectedTableID } ?? card.tables.first }

    var body: some View {
        if let table {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    if card.tables.count > 1 {
                        Picker(card.league, selection: $selectedTableID) {
                            ForEach(card.tables) { table in Text(table.title).tag(table.id) }
                        }.pickerStyle(.menu).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(table.title == card.league ? card.league : "\(card.league) · \(table.title)").font(.headline)
                    }
                    Spacer(minLength: 0)
                    if !showAll, table.rows.count > 5 { Text(L10n.text("Top 5")).font(.callout).foregroundStyle(.secondary) }
                }
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 16) {
                        GridRow {
                            Color.clear.frame(width: 22, height: 1).gridCellUnsizedAxes(.vertical)
                            Text(L10n.text("Team")).frame(width: 200, alignment: .leading)
                            ForEach(table.columns.indices, id: \.self) { index in
                                Text(columnName(table.columns[index])).frame(width: 54, alignment: .trailing)
                                    .help(columnDescription(table.columns[index]))
                            }
                        }.foregroundStyle(.secondary).font(.callout)
                        Divider().gridCellColumns(table.columns.count + 2)
                        ForEach(showAll ? table.rows : Array(table.rows.prefix(5))) { row in
                            GridRow {
                                Text(row.rank.formatted()).foregroundStyle(.secondary).frame(width: 22, alignment: .leading)
                                Text(row.team).fontWeight(.medium).lineLimit(1).frame(width: 200, alignment: .leading).help(row.team)
                                ForEach(row.values.indices, id: \.self) { index in
                                    Text(row.values[index]).monospacedDigit().frame(width: 54, alignment: .trailing)
                                }
                            }.accessibilityElement(children: .combine)
                        }
                    }.padding(.vertical, 2).textSelection(.enabled)
                }.scrollIndicators(.hidden)
                if table.rows.count > 5 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showAll.toggle() }
                    } label: {
                        Label(showAll ? L10n.text("Show top 5") : L10n.format("Show all teams (%@)", table.rows.count.formatted()),
                              appSymbol: showAll ? "chevron.up" : "chevron.down")
                    }
                    .buttonBorderShape(.capsule)
                    .modifier(ResponseCardButtonStyle())
                }
            }
            .padding(20).frame(maxWidth: 620, alignment: .leading)
            .modifier(ResponseCardBackground()).padding(.vertical, 6)
            .onChange(of: selectedTableID) { showAll = false }
        }
    }

    private func columnName(_ value: String) -> String {
        switch value.uppercased() {
        case "W-L": return L10n.text("W–L")
        case "W-L-T": return L10n.text("W–L–T")
        default: return value
        }
    }

    private func columnDescription(_ value: String) -> String {
        switch value.uppercased() {
        case "GP": return L10n.text("Games played")
        case "OTL": return L10n.text("Overtime losses")
        case "PTS": return L10n.text("Points")
        case "W-L": return L10n.text("Wins and losses")
        case "W-L-T": return L10n.text("Wins, losses and ties")
        default: return value
        }
    }
}

private struct ResponseCardButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) }
        else { content.buttonStyle(.bordered) }
    }
}
