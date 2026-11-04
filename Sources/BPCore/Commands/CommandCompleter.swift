import Foundation

public struct CompletionContext: Sendable {
    public var optionNames: [String]
    public var themeNames: [String]

    public init(optionNames: [String], themeNames: [String]) {
        self.optionNames = optionNames
        self.themeNames = themeNames
    }
}

public enum CommandCompleter {
    private static let pathActions: Set<ActionName> = [.open, .sourceConfig, .saveAs, .pageInsert]
    private static let canonical: [String] = ActionName.allCases.map(\.rawValue).sorted()
    private static let aliases: [String] = CommandAliases.table.keys
        .filter { ActionName(rawValue: $0) == nil }.sorted()

    /// Completions for the text after ":", as full replacement lines.
    /// Prefix matches come first (canonical names before aliases); fuzzy
    /// matching is used only when no prefix matches. Directory listings for
    /// path arguments come from `listDirectory`, which receives a
    /// tilde-expanded directory path (no trailing slash) and marks directories with a trailing "/".
    public static func complete(
        _ input: String, context: CompletionContext,
        listDirectory: (String) -> [String] = { _ in [] }
    ) -> [String] {
        guard let space = input.firstIndex(where: \.isWhitespace) else {
            return completeName(input)
        }
        let word = String(input[..<space])
        let arg = String(input[space...].drop(while: \.isWhitespace))
        let lead = word + " "
        guard let action = CommandAliases.resolve(word) else { return [] }

        switch action {
        case .setOption:
            guard !arg.contains(where: \.isWhitespace) else { return [] }
            return matches(arg, in: context.optionNames.sorted()).map { lead + $0 + " " }
        case .setTheme:
            return matches(arg, in: context.themeNames.sorted()).map { lead + $0 }
        default:
            let isPathCommand = pathActions.contains(action) || ["w", "write"].contains(word)
            return isPathCommand ? completePath(arg, lead: lead, listDirectory) : []
        }
    }

    private static func completeName(_ text: String) -> [String] {
        let lower = text.lowercased()
        let prefixed = (canonical + aliases).filter { $0.lowercased().hasPrefix(lower) }
        if !prefixed.isEmpty || text.isEmpty { return (text.isEmpty ? canonical + aliases : prefixed).map { $0 + " " } }
        return FuzzyMatcher.rank(text, in: canonical + aliases, key: { $0 }).map { $0.item + " " }
    }

    /// Prefix matches in input order, else fuzzy-ranked.
    private static func matches(_ query: String, in names: [String]) -> [String] {
        if query.isEmpty { return names }
        let lower = query.lowercased()
        let prefixed = names.filter { $0.lowercased().hasPrefix(lower) }
        if !prefixed.isEmpty { return prefixed }
        return FuzzyMatcher.rank(query, in: names, key: { $0 }).map(\.item)
    }

    private static func completePath(_ arg: String, lead: String, _ list: (String) -> [String]) -> [String] {
        if arg == "~" { return [lead + "~/"] }
        let slash = arg.lastIndex(of: "/")
        let dirPart = slash.map { String(arg[...$0]) } ?? ""
        let partial = slash.map { String(arg[arg.index(after: $0)...]) } ?? arg
        let dirPath = dirPart.isEmpty ? "." : (dirPart as NSString).expandingTildeInPath
        var names = list(dirPath)
        if !partial.hasPrefix(".") { names.removeAll { $0.hasPrefix(".") } }
        names.sort()
        return matches(partial, in: names).map { lead + dirPart + $0 }
    }
}
