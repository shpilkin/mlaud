// swift-tools-version: 5.10
import PackageDescription

// XCTest недоступен в Command Line Tools (нужен полный Xcode), поэтому тесты — отдельный
// исполняемый раннер MLaudTests (запуск: `swift run MLaudTests`).
let package = Package(
    name: "MLaud",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Протокол приёма записей с iPhone. Общий пакет с мобильным приложением
        // намеренно: обе стороны обязаны говорить одним кодом, иначе протокол
        // разъедется по мелочам, которые вылезут только в бою.
        .package(path: "../../mlaud mobile/Core"),
    ],
    targets: [
        // Тестируемая логика без UI.
        .target(name: "MLaudCore"),
        // Меню-бар приложение (AppKit).
        .executableTarget(
            name: "MLaudApp",
            dependencies: [
                "MLaudCore",
                .product(name: "MLaudSync", package: "Core"),
            ]
        ),
        // Тест-раннер без XCTest.
        .executableTarget(
            name: "MLaudTests",
            dependencies: ["MLaudCore"]
        ),
    ]
)
