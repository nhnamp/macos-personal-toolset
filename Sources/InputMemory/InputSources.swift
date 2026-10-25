import Carbon
import Foundation

/// A keyboard layout (ABC) or an input mode (Vietnamese Simple Telex) that the user can select.
public struct InputSource: Hashable, Identifiable {
    public let id: String
    public let name: String
}

/// Wrapper for the Text Input Sources API (TIS).
public enum InputSources {
    /// The keyboard sources in the menu bar's input menu.
    public static func selectable() -> [InputSource] {
        list().compactMap { source in
            guard let id = string(source, kTISPropertyInputSourceID), let name = string(source, kTISPropertyLocalizedName) else { return nil }
            return InputSource(id: id, name: name)
        }
    }

    public static func currentID() -> String? {
        string(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    }

    public static func name(of id: String) -> String {
        selectable().first { $0.id == id }?.name ?? id
    }

    @discardableResult
    public static func select(_ id: String) -> Bool {
        guard let source = list().first(where: { string($0, kTISPropertyInputSourceID) == id }) else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func list() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true,
        ] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }
}
