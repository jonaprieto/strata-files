import Foundation

package nonisolated struct GitCommit: Sendable, Equatable, Hashable {
    package let id: String
    package let parents: [String]
    package let author: String
    package let email: String
    package let date: Date
    /// Branches and tags pointing here, as `git log --decorate` names them ("HEAD -> main", "tag: v1").
    package let refs: [String]
    package let subject: String

    package init(id: String, parents: [String], author: String, email: String, date: Date, refs: [String], subject: String) {
        self.id = id
        self.parents = parents
        self.author = author
        self.email = email
        self.date = date
        self.refs = refs
        self.subject = subject
    }

    package var shortID: String { String(id.prefix(7)) }
    package var isMerge: Bool { parents.count > 1 }
}

/// `git log` with `GitLogParser.format`: fields split by 0x1f, records ended by 0x1e. A record with the wrong number
/// of fields (a subject holding a separator) is left out rather than misread.
package nonisolated enum GitLogParser {
    package static let format = "--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"

    package static func parse(_ data: Data) -> [GitCommit] {
        String(decoding: data, as: UTF8.self).split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, fields[0].count >= 4, fields[0].allSatisfy(\.isHexDigit),
                  let seconds = TimeInterval(fields[4]) else { return nil }
            let refs = fields[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return GitCommit(id: fields[0], parents: fields[1].split(separator: " ").map(String.init), author: fields[2],
                             email: fields[3], date: Date(timeIntervalSince1970: seconds), refs: refs, subject: fields[6])
        }
    }
}

/// One row of the graph: the lane its commit sits in, the lanes that end at it from above, the lanes it continues
/// into below (its parents), and the lanes that pass it by.
package nonisolated struct GitGraphRow: Sendable, Equatable {
    package let node: Int
    package let incoming: [Int]
    package let outgoing: [Int]
    package let passing: [Int]
    /// Lanes in use on this row, for its width.
    package let width: Int

    package init(node: Int, incoming: [Int], outgoing: [Int], passing: [Int], width: Int) {
        self.node = node
        self.incoming = incoming
        self.outgoing = outgoing
        self.passing = passing
        self.width = width
    }
}

/// Lanes for commits in topological order: each lane waits for one commit; a commit takes the lane waiting for it
/// (or a free one), hands it to its first parent, and opens lanes for its other parents.
package nonisolated enum GitGraph {
    package static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var lanes: [String?] = []
        var rows: [GitGraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            let waiting = lanes.indices.filter { lanes[$0] == commit.id }
            let node = waiting.first ?? lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
            if node == lanes.count { lanes.append(nil) }
            let passing = lanes.indices.filter { lanes[$0] != nil && !waiting.contains($0) && $0 != node }
            // Lanes that waited for this commit end here; its own lane goes on to its first parent.
            for lane in waiting { lanes[lane] = nil }
            var outgoing: [Int] = []
            for (index, parent) in commit.parents.enumerated() {
                if index == 0 {
                    lanes[node] = parent
                    outgoing.append(node)
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing.append(existing)
                } else {
                    let free = lanes.firstIndex(where: { $0 == nil }) ?? lanes.count
                    if free == lanes.count { lanes.append(parent) } else { lanes[free] = parent }
                    outgoing.append(free)
                }
            }
            let width = lanes.count
            rows.append(GitGraphRow(node: node, incoming: waiting, outgoing: outgoing, passing: passing, width: width))
            while lanes.last == .some(nil) { lanes.removeLast() }
        }
        return rows
    }
}
