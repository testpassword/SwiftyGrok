#if os(macOS)
import Foundation

/// Uses Foundation's Markdown parser, including its table and list semantics.
public struct MarkdownDocument {
    public struct Block: Identifiable {
        public let id: Int
        public let kind: PresentationIntent.Kind
        public let text: AttributedString
        public let children: [Block]
    }

    public let blocks: [Block]

    public init(_ markdown: String) {
        let math = MathMarkup(markdown)
        guard let parsed = try? AttributedString(markdown: math.markdown, options: .init(interpretedSyntax: .full)) else {
            blocks = [Block(id: 0, kind: .paragraph, text: AttributedString(markdown), children: [])]
            return
        }
        var roots: [Node] = []
        var nodes: [Int: Node] = [:]
        for (intent, range) in parsed.runs[\.presentationIntent] {
            guard let intent else {
                roots.append(Node(id: -roots.count - 1, kind: .paragraph, text: AttributedString(parsed[range])))
                continue
            }
            var parent: Node?
            for component in intent.components.reversed() {
                let node: Node
                if let existing = nodes[component.identity] {
                    node = existing
                } else {
                    node = Node(id: component.identity, kind: component.kind)
                    nodes[component.identity] = node
                    if let parent { parent.children.append(node) }
                    else { roots.append(node) }
                }
                parent = node
            }
            var text = AttributedString(parsed[range])
            text.presentationIntent = nil
            parent?.text.append(text)
        }
        blocks = roots.map { $0.block(math: math) }
    }

    private final class Node {
        let id: Int
        let kind: PresentationIntent.Kind
        var text: AttributedString
        var children: [Node] = []
        init(id: Int, kind: PresentationIntent.Kind, text: AttributedString = AttributedString()) {
            self.id = id; self.kind = kind; self.text = text
        }
        func block(math: MathMarkup) -> Block {
            let literal: Bool
            if case .codeBlock = kind { literal = true } else { literal = false }
            return Block(id: id, kind: kind, text: math.restore(text, literal: literal), children: children.map { $0.block(math: math) })
        }
    }
}
#endif
