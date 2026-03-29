import Foundation

enum SplitDirection: String, Codable {
    case horizontal // side by side (left | right)
    case vertical   // stacked (top / bottom)
}

indirect enum SplitNode: Codable, Identifiable, Equatable {
    case pane(id: UUID, workingDirectory: String)
    case split(id: UUID, direction: SplitDirection, first: SplitNode, second: SplitNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .pane(let id, _): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    var isLeaf: Bool {
        if case .pane = self { return true }
        return false
    }

    /// All pane (leaf) IDs in tree order
    var allPaneIds: [UUID] {
        switch self {
        case .pane(let id, _): return [id]
        case .split(_, _, let first, let second, _):
            return first.allPaneIds + second.allPaneIds
        }
    }

    func containsPane(_ paneId: UUID) -> Bool {
        switch self {
        case .pane(let id, _): return id == paneId
        case .split(_, _, let first, let second, _):
            return first.containsPane(paneId) || second.containsPane(paneId)
        }
    }

    func workingDirectory(for paneId: UUID) -> String? {
        switch self {
        case .pane(let id, let dir):
            return id == paneId ? dir : nil
        case .split(_, _, let first, let second, _):
            return first.workingDirectory(for: paneId) ?? second.workingDirectory(for: paneId)
        }
    }

    func updatingWorkingDirectory(_ paneId: UUID, to dir: String) -> SplitNode {
        switch self {
        case .pane(let id, let wd):
            return id == paneId ? .pane(id: id, workingDirectory: dir) : .pane(id: id, workingDirectory: wd)
        case .split(let id, let direction, let first, let second, let ratio):
            return .split(id: id, direction: direction,
                          first: first.updatingWorkingDirectory(paneId, to: dir),
                          second: second.updatingWorkingDirectory(paneId, to: dir),
                          ratio: ratio)
        }
    }

    /// Replace the target pane with a split containing the original + a new pane.
    /// Returns the new tree and the new pane's ID.
    func splitting(_ paneId: UUID, direction: SplitDirection) -> (SplitNode, UUID) {
        switch self {
        case .pane(let id, let dir):
            guard id == paneId else { return (self, id) }
            let newPaneId = UUID()
            let node = SplitNode.split(
                id: UUID(), direction: direction,
                first: .pane(id: id, workingDirectory: dir),
                second: .pane(id: newPaneId, workingDirectory: dir),
                ratio: 0.5
            )
            return (node, newPaneId)
        case .split(let id, let dir, let first, let second, let ratio):
            if first.containsPane(paneId) {
                let (newFirst, newId) = first.splitting(paneId, direction: direction)
                return (.split(id: id, direction: dir, first: newFirst, second: second, ratio: ratio), newId)
            } else if second.containsPane(paneId) {
                let (newSecond, newId) = second.splitting(paneId, direction: direction)
                return (.split(id: id, direction: dir, first: first, second: newSecond, ratio: ratio), newId)
            }
            return (self, id)
        }
    }

    /// Remove a pane. Returns the remaining tree, or nil if it was the only pane.
    func removing(_ paneId: UUID) -> SplitNode? {
        switch self {
        case .pane(let id, _):
            return id == paneId ? nil : self
        case .split(let id, let direction, let first, let second, let ratio):
            // Direct child is the target leaf
            if case .pane(let fid, _) = first, fid == paneId { return second }
            if case .pane(let sid, _) = second, sid == paneId { return first }
            // Recurse
            if first.containsPane(paneId) {
                if let newFirst = first.removing(paneId) {
                    return .split(id: id, direction: direction, first: newFirst, second: second, ratio: ratio)
                }
                return second
            }
            if second.containsPane(paneId) {
                if let newSecond = second.removing(paneId) {
                    return .split(id: id, direction: direction, first: first, second: newSecond, ratio: ratio)
                }
                return first
            }
            return self
        }
    }

    /// Next pane ID after the given one (wraps around)
    func nextPaneId(after paneId: UUID) -> UUID? {
        let ids = allPaneIds
        guard let index = ids.firstIndex(of: paneId) else { return ids.first }
        return ids[(index + 1) % ids.count]
    }

    /// Previous pane ID before the given one (wraps around)
    func previousPaneId(before paneId: UUID) -> UUID? {
        let ids = allPaneIds
        guard let index = ids.firstIndex(of: paneId) else { return ids.last }
        return ids[(index - 1 + ids.count) % ids.count]
    }
}
