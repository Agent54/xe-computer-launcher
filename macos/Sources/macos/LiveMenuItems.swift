import AppKit

/// Keep native rows (and their open submenus) alive across state refreshes.
@MainActor
final class LiveMenuItems<Key: Hashable> {
    let menu: NSMenu
    private var rows: [Key: NSMenuItem] = [:]
    private let insertionIndex: Int

    init(menu: NSMenu = NSMenu()) {
        self.menu = menu
        insertionIndex = menu.numberOfItems
        menu.autoenablesItems = false
    }

    func update(
        keys: [Key], deferStructuralChanges: Bool = false,
        configure: (Key, NSMenuItem) -> Void
    ) {
        if !deferStructuralChanges {
            for key in Array(rows.keys) where !keys.contains(key) {
                if let row = rows.removeValue(forKey: key) { menu.removeItem(row) }
            }
            for (index, key) in keys.enumerated() {
                let row = rows[key] ?? NSMenuItem(title: "", action: nil, keyEquivalent: "")
                rows[key] = row
                if menu.index(of: row) != insertionIndex + index {
                    if row.menu != nil { menu.removeItem(row) }
                    menu.insertItem(row, at: insertionIndex + index)
                }
            }
        }
        for key in keys {
            if let row = rows[key] { configure(key, row) }
        }
        // A removed warning must not remain actionable while its row is kept
        // alive until tracking ends.
        for (key, row) in rows where !keys.contains(key) { row.isEnabled = false }
    }
}
