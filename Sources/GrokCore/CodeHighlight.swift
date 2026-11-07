import Foundation

/// Small, non-executing lexer for chat code. Strings and comments are matched
/// before identifiers so their contents cannot be recolored as keywords.
public enum CodeHighlight {
    public enum Kind: Equatable, Sendable { case plain, keyword, string, comment, number, type, function }
    public struct Segment: Equatable, Sendable {
        public let text: String
        public let kind: Kind
    }

    private struct Language {
        let words: Set<String>
        var hashComments = false
        var slashComments = false
        var dashComments = false
        var multilineQuotes = false
        var backticks = false
        var json = false
    }

    public static func segments(_ code: String, language: String?) -> [Segment] {
        let name = language?.lowercased().split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        guard let language = configuration(name) else { return [Segment(text: code, kind: .plain)] }
        var strings = [#""(?:\\[\s\S]|[^"\\])*"?"#, #"'(?:\\[\s\S]|[^'\\])*'?"#]
        if language.json { strings.removeLast() }
        if language.multilineQuotes {
            strings.insert(#""""[\s\S]*?(?:"""|\z)"#, at: 0)
            strings.insert(#"'''[\s\S]*?(?:'''|\z)"#, at: 0)
        }
        if language.backticks { strings.insert(#"`(?:\\[\s\S]|[^`\\])*`?"#, at: 0) }
        var comments: [String] = []
        if language.hashComments { comments.append("#[^\\r\\n]*") }
        if language.slashComments { comments += [#"//[^\r\n]*"#, #"/\*[\s\S]*?(?:\*/|\z)"#] }
        if language.dashComments { comments.append("--[^\\r\\n]*") }
        var patterns = ["(?<string>" + strings.joined(separator: "|") + ")"]
        if !comments.isEmpty { patterns.append("(?<comment>" + comments.joined(separator: "|") + ")") }
        patterns += [#"(?<number>\b(?:0[xX][\da-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?))"#,
                     #"(?<word>[\p{L}_$][\p{L}\p{N}_$]*)"#]
        guard let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|")) else { return [Segment(text: code, kind: .plain)] }
        let source = code as NSString
        var result: [Segment] = []
        var offset = 0
        for match in regex.matches(in: code, range: NSRange(location: 0, length: source.length)) {
            if match.range.location > offset {
                result.append(Segment(text: source.substring(with: NSRange(location: offset, length: match.range.location - offset)), kind: .plain))
            }
            let text = source.substring(with: match.range)
            let following = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted,
                range: NSRange(location: NSMaxRange(match.range), length: source.length - NSMaxRange(match.range)))
            let kind: Kind
            if match.range(withName: "string").location != NSNotFound { kind = .string }
            else if !comments.isEmpty && match.range(withName: "comment").location != NSNotFound { kind = .comment }
            else if match.range(withName: "number").location != NSNotFound { kind = .number }
            else if language.words.contains(language.dashComments ? text.lowercased() : text) { kind = .keyword }
            else if !language.json, text.first?.isUppercase == true { kind = .type }
            else if !language.json, following.location != NSNotFound, source.character(at: following.location) == 40 { kind = .function }
            else { kind = .plain }
            result.append(Segment(text: text, kind: kind))
            offset = NSMaxRange(match.range)
        }
        if offset < source.length { result.append(Segment(text: source.substring(from: offset), kind: .plain)) }
        return result
    }

    private static func configuration(_ name: String) -> Language? {
        func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
        switch name {
        case "python", "py", "python3":
            return Language(words: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield"), hashComments: true, multilineQuotes: true)
        case "swift":
            return Language(words: words("actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in init inout internal is isolated lazy let mutating nil nonisolated nonmutating open operator optional override private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet"), slashComments: true, multilineQuotes: true)
        case "javascript", "js", "jsx", "typescript", "ts", "tsx", "java", "kotlin", "kt", "c", "cpp", "c++", "csharp", "cs", "c#", "go", "rust", "rs", "css":
            return Language(words: words("abstract as async await boolean break case catch char class const continue debugger default defer delete do double else enum export extends false final finally float fn for from func function if implements import in instanceof int interface let match mut namespace new null package private protected pub public return self static string struct super switch this throw throws trait true try type typeof undefined use using var virtual void when while yield"), slashComments: true, backticks: true)
        case "json", "jsonc":
            return Language(words: words("true false null"), slashComments: name == "jsonc", json: true)
        case "bash", "sh", "shell", "zsh", "powershell", "ps1", "yaml", "yml", "ruby", "rb", "toml":
            return Language(words: words("if then else elif fi for do done in while until case esac function return exit export local readonly echo true false null nil def end class module require rescue ensure begin unless yield"), hashComments: true, backticks: true)
        case "sql":
            return Language(words: words("select from where join left right inner outer on as group by order having limit offset union all insert into values update set delete create alter drop table index primary key foreign references null not and or in is true false distinct count sum case when then else end with returning"), slashComments: true, dashComments: true)
        default: return nil
        }
    }
}
