// Menu-bar status item that gives the user quick GUI access to display
// switching, status, and quitting — without needing to drop into a
// terminal. The item lives next to the system clock; clicking opens
// a simple menu.
import AppKit

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private let model: AppModel
    private let onCycleDisplay: () -> Void
    private let onSelectDisplay: (DisplayTarget) -> Void

    init(
        model: AppModel,
        onCycleDisplay: @escaping () -> Void,
        onSelectDisplay: @escaping (DisplayTarget) -> Void
    ) {
        self.model = model
        self.onCycleDisplay = onCycleDisplay
        self.onSelectDisplay = onSelectDisplay
        super.init()
        install()
    }

    private func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "blip"
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            button.toolTip = "blip — Claude Code notch (toggle via `blip config set menuBarEnabled false`)"
        }
        rebuildMenu()
    }

    func uninstall() {
        if statusItem != nil {
            NSStatusBar.system.removeStatusItem(statusItem)
            statusItem = nil
        }
    }

    /// Rebuilds the menu on each display so checkmarks reflect the
    /// current target.
    func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "blip.vim", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for target in DisplayTarget.allCases {
            let item = NSMenuItem(
                title: "Display: \(target.label)",
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target
            item.state = (model.displayTarget == target) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Cycle display target", action: #selector(cycleDisplay), shortcut: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem(title: "Quit blip", action: #selector(quit), shortcut: "q"))

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? DisplayTarget else { return }
        onSelectDisplay(target)
        rebuildMenu()
    }

    @objc private func cycleDisplay() {
        onCycleDisplay()
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func makeItem(title: String, action: Selector, shortcut: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: shortcut)
        item.target = self
        return item
    }
}
