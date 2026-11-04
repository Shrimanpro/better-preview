import Foundation

enum CommandAliases {
    /// Alias -> action. Aliases win over canonical names (`quit` closes the
    /// document, `qall` quits the app). `w`/`write` additionally turn an
    /// argument into save-as; that is handled by the parser.
    static let table: [String: ActionName] = [
        "q": .close, "quit": .close,
        "qa": .quit, "qall": .quit,
        "w": .save, "write": .save,
        "e": .open, "edit": .open, "o": .open,
        "r": .reload,
        "p": .print, "hardcopy": .print,
        "g": .gotoPage, "goto": .gotoPage,
        "zoom": .zoomSet,
        "hl": .annotateHighlight, "highlight": .annotateHighlight,
        "nohl": .searchClear, "nohlsearch": .searchClear,
        "so": .sourceConfig,
        "colorscheme": .setTheme, "colo": .setTheme,
        "first": .gotoFirst, "last": .gotoLast,
        "next": .pageNext, "n": .pageNext,
        "prev": .pagePrevious, "previous": .pagePrevious, "N": .pagePrevious,
        "fs": .toggleFullscreen, "fullscreen": .toggleFullscreen,
        "pres": .togglePresentation, "presentation": .togglePresentation,
        "sidebar": .toggleSidebar,
        "toolbar": .toggleToolbar,
        "recolor": .toggleRecolor,
        "trim": .toggleTrim,
        "dual": .toggleDualPage,
        "rotate": .rotateCW,
    ]

    static func resolve(_ word: String) -> ActionName? {
        table[word] ?? ActionName(rawValue: word)
    }
}
