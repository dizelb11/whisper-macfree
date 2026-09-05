// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dictate",
            // Строгая изоляция Swift 6 плохо дружит с C-колбэками CGEventTap,
            // а выгоды здесь нет: всё живёт на главном потоке.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
