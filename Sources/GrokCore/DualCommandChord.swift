/// Fires once per press of both Command keys; both must be released to rearm.
public struct DualCommandChord: Sendable {
    private var latched: Bool

    public init(leftPressed: Bool = false, rightPressed: Bool = false) {
        latched = leftPressed || rightPressed
    }

    public mutating func update(leftPressed: Bool, rightPressed: Bool, otherModifiers: Bool = false) -> Bool {
        if !leftPressed && !rightPressed { latched = false; return false }
        guard !latched, leftPressed && rightPressed else { return false }
        latched = true
        return !otherModifiers
    }
}
