import AppKit
import Foundation

public struct ClipboardSnapshot: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let representations: [String: Data]

        public init(representations: [String: Data]) {
            self.representations = representations
        }
    }

    public let items: [Item]
    public let changeCount: Int
    public let isPartial: Bool

    public init(items: [Item], changeCount: Int, isPartial: Bool) {
        self.items = items
        self.changeCount = changeCount
        self.isPartial = isPartial
    }

    public var isEmpty: Bool { items.allSatisfy(\.representations.isEmpty) }
}

@MainActor
public enum Clipboard {
    public static func capture(_ pasteboard: NSPasteboard = .general) -> ClipboardSnapshot {
        var items: [ClipboardSnapshot.Item] = []
        var partial = false
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    partial = true
                    continue
                }
                representations[type.rawValue] = data
            }
            items.append(ClipboardSnapshot.Item(representations: representations))
        }
        return ClipboardSnapshot(
            items: items, changeCount: pasteboard.changeCount, isPartial: partial)
    }

    @discardableResult
    public static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Int? {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string) ? pasteboard.changeCount : nil
    }

    @discardableResult
    public static func restore(
        _ snapshot: ClipboardSnapshot, ourChangeCount: Int?, to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard
            let ourChangeCount,
            DeliveryPolicy.shouldRestoreClipboard(
                ourChangeCount: ourChangeCount, currentChangeCount: pasteboard.changeCount)
        else { return false }

        if snapshot.isEmpty {
            pasteboard.clearContents()
            return true
        }

        let restored = snapshot.items.compactMap { item -> NSPasteboardItem? in
            guard !item.representations.isEmpty else { return nil }
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.representations {
                pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return pasteboardItem
        }
        guard !restored.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects(restored)
    }
}
