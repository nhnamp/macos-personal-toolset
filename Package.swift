// swift-tools-version:6.0
import PackageDescription

// One target per feature. ToolsetCore holds the code that every feature shares.
// ToolsetApp is the menu bar app that hosts all features.
let package = Package(
    name: "MacOSPersonalToolset",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ToolsetCore", path: "Sources/ToolsetCore"),
        .target(name: "InputMemory", dependencies: ["ToolsetCore"], path: "Sources/InputMemory"),
        .target(name: "HiDPI", dependencies: ["ToolsetCore"], path: "Sources/HiDPI"),
        .target(name: "WindowSwitcher", dependencies: ["ToolsetCore"], path: "Sources/WindowSwitcher"),
        .target(name: "SpaceProfiles", dependencies: ["ToolsetCore"], path: "Sources/SpaceProfiles"),
        .target(name: "MouseScroll", dependencies: ["ToolsetCore"], path: "Sources/MouseScroll"),
        .target(name: "KeyboardLock", dependencies: ["ToolsetCore"], path: "Sources/KeyboardLock"),
        .executableTarget(name: "ToolsetApp", dependencies: ["ToolsetCore", "InputMemory", "HiDPI", "WindowSwitcher", "SpaceProfiles", "MouseScroll", "KeyboardLock"], path: "Sources/ToolsetApp"),
    ],
    swiftLanguageModes: [.v5]
)
