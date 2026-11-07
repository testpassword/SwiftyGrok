import SwiftUI

@MainActor struct CodeLanguageIcon: View {
    let language: String?

    var body: some View {
        Group {
            if let assetName {
                Image(assetName, bundle: resourceBundle)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "terminal")
            }
        }
        .accessibilityHidden(true)
    }

    private var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    private var assetName: String? {
        guard let name = language?.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() else { return nil }
        let icon: String
        switch name {
        case "python", "python3", "py", "py3": icon = "python"
        case "swift": icon = "swift"
        case "javascript", "js", "jsx", "node", "nodejs", "mjs", "cjs": icon = "javascript"
        case "typescript", "ts", "tsx", "mts", "cts": icon = "typescript"
        case "java": icon = "java"
        case "kotlin", "kt", "kts": icon = "kotlin"
        case "c", "h": icon = "c"
        case "cpp", "c++", "cplusplus", "cc", "cxx", "hpp", "hxx": icon = "cplusplus"
        case "csharp", "c#", "cs": icon = "csharp"
        case "go", "golang": icon = "go"
        case "rust", "rs": icon = "rust"
        case "css", "css3": icon = "css3"
        case "json", "jsonc", "json5": icon = "json"
        case "bash", "sh", "shell", "shellscript": icon = "bash"
        case "zsh": icon = "zsh"
        case "powershell", "ps1", "pwsh": icon = "powershell"
        case "yaml", "yml": icon = "yaml"
        case "ruby", "rb": icon = "ruby"
        case "toml": icon = "toml"
        case "html", "html5", "htm": icon = "html5"
        case "php": icon = "php"
        case "dart": icon = "dart"
        case "objective-c", "objectivec", "objc", "objective-c++", "objcpp": icon = "objectivec"
        case "r": icon = "r"
        case "scala", "sc": icon = "scala"
        case "lua": icon = "lua"
        case "elixir", "ex", "exs": icon = "elixir"
        case "erlang", "erl": icon = "erlang"
        case "haskell", "hs": icon = "haskell"
        case "perl", "pl": icon = "perl"
        case "julia", "jl": icon = "julia"
        case "docker", "dockerfile": icon = "docker"
        case "markdown", "md", "mdx": icon = "markdown"
        case "xml", "svg", "xhtml": icon = "xml"
        default: return nil
        }
        return "CodeLanguage-\(icon)"
    }
}
