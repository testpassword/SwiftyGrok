import Foundation

public struct SportsStandingsCard: Identifiable, Equatable, Sendable {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: Int
        public let rank: Int
        public let team: String
        public let values: [String]
    }
    public struct Table: Identifiable, Equatable, Sendable {
        public let id: Int
        public let title: String
        public let columns: [String]
        public let rows: [Row]
    }
    public let id: String
    public let league: String
    public let tables: [Table]

    init?(_ json: [String: Any]) {
        guard let id = CardJSON.string(json, "id"), let sport = CardJSON.string(json, "sport") else { return nil }
        let standings = CardJSON.object(json, "standings")
        let groups = standings["standings"] as? [[String: Any]] ?? []
        tables = groups.prefix(32).enumerated().compactMap { index, group in
            guard let markdown = CardJSON.string(group, "table") else { return nil }
            let lines = markdown.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("|") }
            guard let header = lines.first else { return nil }
            let columns = Self.cells(header)
            guard !columns.isEmpty, columns.count <= 32 else { return nil }
            let teamIndex = columns.firstIndex { ["team", "club", "name"].contains($0.lowercased()) } ?? 0
            let rows = lines.dropFirst().prefix(256).map(Self.cells).filter { cells in
                cells.count == columns.count && !cells.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
            }
            let stats = columns.indices.filter { $0 != teamIndex }
            let wins = stats.first { columns[$0].uppercased() == "W" }
            let losses = stats.first { columns[$0].uppercased() == "L" }
            let ties = stats.first { columns[$0].uppercased() == "T" }
            let includeTies = ties.map { t in rows.contains { (Double($0[t]) ?? 0) != 0 } } ?? false
            let other = stats.filter { $0 != wins && $0 != losses && $0 != ties }
            let displayColumns: [String]
            if wins != nil && losses != nil {
                displayColumns = [includeTies ? "W-L-T" : "W-L"] + other.prefix(2).map { columns[$0] }
            } else { displayColumns = stats.prefix(3).map { columns[$0] } }
            let rendered = rows.enumerated().compactMap { offset, cells -> Row? in
                let name = cells[teamIndex]
                guard !name.isEmpty else { return nil }
                let values: [String]
                if let wins, let losses {
                    var record = [cells[wins], cells[losses]]
                    if includeTies, let ties { record.append(cells[ties]) }
                    values = [record.joined(separator: "–")] + other.prefix(2).map { cells[$0] }
                } else { values = stats.prefix(3).map { cells[$0] } }
                return Row(id: offset, rank: offset + 1, team: name, values: values)
            }
            guard !rendered.isEmpty else { return nil }
            return Table(id: index, title: CardJSON.string(group, "scope") ?? sport.uppercased(), columns: displayColumns, rows: rendered)
        }
        guard !tables.isEmpty else { return nil }
        self.id = id; league = sport.uppercased()
    }

    /// The backend sends Markdown tables. Honor escaped pipes and code spans so
    /// a team label cannot shift the numerical columns of the remaining rows.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = [], cell = "", escaped = false, code = false
        for character in line {
            if escaped { cell.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "`" { code.toggle(); continue }
            if character == "|", !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(character) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}
