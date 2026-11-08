import AppKit
import BPCore

/// Menu items carry an action name and go through the same dispatch path as
/// keys and `:` commands.
final class ActionMenuItem: NSMenuItem {
    var invocation: ActionInvocation?

    convenience init(_ title: String, _ name: ActionName, _ argument: String? = nil,
                     key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
        self.init(title: title, action: #selector(DocumentWindowController.performMenuAction(_:)),
                  keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        invocation = ActionInvocation(name, argument)
    }
}

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Better Preview"

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, titled: appName, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.showOpenPanel as (AppDelegate) -> () -> Void), keyEquivalent: "o")
        file.addItem(ActionMenuItem("Open Quickly…", .openPalette, key: "o", modifiers: [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(ActionMenuItem("Save", .save, key: "s"))
        file.addItem(ActionMenuItem("Save As…", .saveAs, key: "s", modifiers: [.command, .shift]))
        file.addItem(ActionMenuItem("Reload", .reload, key: "r", modifiers: [.command, .option]))
        file.addItem(.separator())
        add(file, titled: "File", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(ActionMenuItem("Undo", .undo, key: "z"))
        edit.addItem(ActionMenuItem("Redo", .redo, key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        // Cut, Paste and Delete are nil-targeted standard actions: a focused
        // text view (input bar, form field, text box, palette, password
        // field) handles them; Delete otherwise reaches
        // DocumentWindowController.delete(_:) (the selected annotation).
        // Copy, Select All, Undo and Redo go to a focused text view too (see
        // performMenuAction), else to the document.
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(ActionMenuItem("Copy", .copy, key: "c"))
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}")
        edit.addItem(ActionMenuItem("Select All", .selectAll, key: "a"))
        edit.addItem(.separator())
        edit.addItem(ActionMenuItem("Find…", .searchForward, key: "f"))
        edit.addItem(ActionMenuItem("Find Backward…", .searchBackward, key: "f", modifiers: [.command, .option]))
        edit.addItem(ActionMenuItem("Find Next", .searchNext, key: "g"))
        edit.addItem(ActionMenuItem("Find Previous", .searchPrevious, key: "g", modifiers: [.command, .shift]))
        edit.addItem(ActionMenuItem("Clear Search", .searchClear))
        add(edit, titled: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(ActionMenuItem("Show Status Bar", .toggleStatusbar, key: "/"))
        view.addItem(ActionMenuItem("Show Inspector", .toggleInspector, key: "i", modifiers: [.command, .option]))
        view.addItem(.separator())
        view.addItem(ActionMenuItem("Actual Size", .zoomReset, key: "0"))
        view.addItem(ActionMenuItem("Zoom to Fit", .fitPage, key: "9"))
        view.addItem(ActionMenuItem("Fit Width", .fitWidth, key: "8"))
        view.addItem(ActionMenuItem("Zoom In", .zoomIn, key: "+"))
        view.addItem(ActionMenuItem("Zoom Out", .zoomOut, key: "-"))
        view.addItem(.separator())
        view.addItem(ActionMenuItem("Continuous Scroll", .toggleContinuous, key: "1"))
        view.addItem(ActionMenuItem("Two Pages", .toggleDualPage, key: "2"))
        view.addItem(ActionMenuItem("Recolor Pages", .toggleRecolor))
        view.addItem(ActionMenuItem("Trim Margins", .toggleTrim))
        view.addItem(.separator())
        view.addItem(ActionMenuItem("Enter Full Screen", .toggleFullscreen, key: "f", modifiers: [.command, .control]))
        add(view, titled: "View", to: main)

        let go = NSMenu(title: "Go")
        go.addItem(ActionMenuItem("Next Page", .pageNext, key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                                  modifiers: [.command]))
        go.addItem(ActionMenuItem("Previous Page", .pagePrevious, key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                                  modifiers: [.command]))
        go.addItem(ActionMenuItem("First Page", .gotoFirst, key: String(UnicodeScalar(NSHomeFunctionKey)!), modifiers: []))
        go.addItem(ActionMenuItem("Last Page", .gotoLast, key: String(UnicodeScalar(NSEndFunctionKey)!), modifiers: []))
        go.addItem(ActionMenuItem("Go to Page…", .enterCommand, "goto-page ", key: "g", modifiers: [.command, .option]))
        go.addItem(.separator())
        go.addItem(ActionMenuItem("Back", .jumpBack, key: "[", modifiers: [.command]))
        go.addItem(ActionMenuItem("Forward", .jumpForward, key: "]", modifiers: [.command]))
        go.addItem(.separator())
        go.addItem(ActionMenuItem("Command Line…", .enterCommand, key: ";", modifiers: [.command, .shift]))
        add(go, titled: "Go", to: main)

        let tools = NSMenu(title: "Tools")
        tools.addItem(ActionMenuItem("Rotate Left", .rotateCCW, key: "l"))
        tools.addItem(ActionMenuItem("Rotate Right", .rotateCW, key: "r"))
        add(tools, titled: "Tools", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(window, titled: "Window", to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(ActionMenuItem("Reload Configuration", .sourceConfig))
        add(help, titled: "Help", to: main)
        NSApp.helpMenu = help

        return main
    }

    private static func addSubmenu(_ menu: NSMenu, titled title: String, to parent: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        parent.addItem(item)
    }

    private static func add(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
