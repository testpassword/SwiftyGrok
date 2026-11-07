#if os(macOS)
import AppKit
import SwiftMath

public struct RenderedMath {
    public let image: NSImage
    public let descent: CGFloat
}

@MainActor public enum MathTypesetter {
    private final class Cached: NSObject {
        let value: RenderedMath
        init(_ value: RenderedMath) { self.value = value }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>()
        cache.countLimit = 256
        return cache
    }()

    public static func render(_ expression: MathExpression, fontSize: CGFloat) -> RenderedMath? {
        guard !expression.latex.isEmpty, expression.latex.count <= 12_000 else { return nil }
        let key = "\(fontSize):\(expression.display):\(expression.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var renderer = MathImage(latex: expression.latex, fontSize: fontSize, textColor: .black,
                                 labelMode: expression.display ? .display : .text)
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image, let layout, image.size.width > 0, image.size.height > 0 else { return nil }
        image.isTemplate = true
        let rendered = RenderedMath(image: image, descent: layout.descent)
        cache.setObject(Cached(rendered), forKey: key)
        return rendered
    }
}
#endif
