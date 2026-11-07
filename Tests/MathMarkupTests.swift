import XCTest
@testable import GrokCore

final class MathMarkupTests: XCTestCase {
    func testProtectsDisplayAndInlineBeforeMarkdownConsumesBackslashes() {
        let source = #"Euler: \[ e^{i\pi} + 1 = 0 \] Constants: \(e\), \(i\), \(\pi\)."#
        let markup = MathMarkup(source)
        XCTAssertEqual(markup.expressions.count, 4)
        XCTAssertEqual(markup.expressions.values.first { $0.display }?.latex, #"e^{i\pi} + 1 = 0"#)
        let restored = markup.restore(AttributedString(markup.markdown), literal: true)
        XCTAssertEqual(String(restored.characters), source)
        let attributed = markup.restore(AttributedString(markup.markdown))
        XCTAssertEqual(attributed.runs.compactMap { $0[MathExpressionAttribute.self] }.count, 4)
    }

    func testCodeFencesInlineCodeAndCurrencyRemainLiteral() {
        let source = #"""
        ```latex
        \[x^2\] $y$
        ```
        ~~~~
        $$not_math$$
        ~~~~
        `\(literal\)` and ``$also_literal$``. Cost \$20 and $20-$30, or $20 and $30.
        Real: $x^2$, $$\frac{1}{2}$$, \(π\).
        """#
        let markup = MathMarkup(source)
        XCTAssertEqual(markup.expressions.count, 3)
        XCTAssertEqual(Set(markup.expressions.values.map(\.latex)), ["x^2", #"\frac{1}{2}"#, "π"])
        XCTAssertEqual(String(markup.restore(AttributedString(markup.markdown), literal: true).characters), source)
    }

    func testUnclosedStreamingFormulaStaysReadable() {
        for source in [#"\[\frac{1}{2}"#, #"value \(x"#, "$$x", "$20"] {
            let markup = MathMarkup(source)
            XCTAssertTrue(markup.expressions.isEmpty)
            XCTAssertEqual(markup.markdown, source)
        }
    }

    #if os(macOS)
    func testMarkdownKeepsMathInListsTablesAndCodeLiteral() {
        let document = MarkdownDocument(#"""
        - **Result**: \(x_i^2\)

        | Formula | Value |
        | --- | --- |
        | $a|b$ | 1 |

            \(literal\)
        """#)
        func flatten(_ blocks: [MarkdownDocument.Block]) -> [MarkdownDocument.Block] {
            blocks.flatMap { [$0] + flatten($0.children) }
        }
        let blocks = flatten(document.blocks)
        let formulas = blocks.flatMap { $0.text.runs.compactMap { $0[MathExpressionAttribute.self] } }
        XCTAssertEqual(Set(formulas.map(\.latex)), ["x_i^2", "a|b"])
        XCTAssertTrue(blocks.contains { if case .codeBlock = $0.kind { return String($0.text.characters).contains(#"\(literal\)"#) }; return false })
    }

    @MainActor func testNativeTypesetterDrawsEulerFractionsIntegralsAndMatrices() {
        for latex in [#"e^{i\pi}+1=0"#, #"\frac{x_1^2}{\sqrt{y}}"#, #"\int_0^1 x^2\,dx"#, #"\begin{bmatrix}a&b\\c&d\end{bmatrix}"#] {
            let rendered = MathTypesetter.render(MathExpression(latex: latex, display: true), fontSize: 22)
            XCTAssertNotNil(rendered, latex)
            XCTAssertGreaterThan(rendered?.image.size.width ?? 0, 0)
            XCTAssertGreaterThan(rendered?.image.size.height ?? 0, 0)
            XCTAssertNotNil(rendered?.image.tiffRepresentation)
        }
        XCTAssertNil(MathTypesetter.render(MathExpression(latex: #"\unknowncommand{"#, display: false), fontSize: 15))
    }

    @MainActor func testQuadraticFormulaAndExplicitFractionStylesRender() throws {
        let quadratic = MathTypesetter.render(MathExpression(latex: #"x = \dfrac{-b \pm \sqrt{b^{2} - 4ac}}{2a}"#, display: true), fontSize: 22)
        XCTAssertNotNil(quadratic?.image.tiffRepresentation)
        let display = try XCTUnwrap(MathTypesetter.render(MathExpression(latex: #"\dfrac{1}{2}"#, display: false), fontSize: 22))
        let text = try XCTUnwrap(MathTypesetter.render(MathExpression(latex: #"\tfrac{1}{2}"#, display: false), fontSize: 22))
        XCTAssertGreaterThan(display.image.size.height, text.image.size.height)
        XCTAssertNotNil(MathTypesetter.render(MathExpression(latex: #"\dfrac{1}{\tfrac{a}{b}} + \frac{c}{d}"#, display: true), fontSize: 22))
    }
    #endif
}
