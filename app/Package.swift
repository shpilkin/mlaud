// swift-tools-version: 5.10
import PackageDescription

// XCTest недоступен в Command Line Tools (нужен полный Xcode), поэтому тесты — отдельный
// исполняемый раннер MLaudTests (запуск: `swift run MLaudTests`).
let package = Package(
    name: "MLaud",
    platforms: [.macOS(.v13)],
    targets: [
        // Тестируемая логика без UI.
        .target(name: "MLaudCore"),
        // Меню-бар приложение (AppKit).
        .executableTarget(
            name: "MLaudApp",
            dependencies: ["MLaudCore"]
        ),
        // Тест-раннер без XCTest.
        .executableTarget(
            name: "MLaudTests",
            dependencies: ["MLaudCore"]
        ),
    ]
)
