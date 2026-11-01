// swift-tools-version: 5.10
import PackageDescription

// XCTest недоступен в Command Line Tools (нужен полный Xcode), поэтому тесты — отдельный
// исполняемый раннер MLaudTests (запуск: `swift run MLaudTests`).
let package = Package(
    name: "MLaud",
    // 15.0 — ADR-020: process taps есть с 14.2, SwiftUI поколения 2024 — с 15; поднимать выше разрешено.
    platforms: [.macOS("15.0")],
    dependencies: [
        // Протокол приёма записей с iPhone. Общий пакет с мобильным приложением
        // намеренно: обе стороны обязаны говорить одним кодом, иначе протокол
        // разъедется по мелочам, которые вылезут только в бою.
        .package(path: "../../mlaud mobile/Core"),
        // Дизайн-система Niti — общий пакет с мобильным приложением (ADR-019),
        // расширенный на macOS в спайке S3.
        .package(path: "../../mlaud mobile/DesignSystem"),
    ],
    targets: [
        // Тестируемая логика без UI.
        .target(name: "MLaudCore"),
        // Приложение: оболочка AppKit (строка меню, окна, процессы), экраны — SwiftUI.
        .executableTarget(
            name: "MLaudApp",
            dependencies: [
                "MLaudCore",
                .product(name: "MLaudSync", package: "Core"),
                .product(name: "NitiUI", package: "DesignSystem"),
            ]
        ),
        // Тест-раннер без XCTest.
        .executableTarget(
            name: "MLaudTests",
            dependencies: ["MLaudCore"]
        ),
    ]
)
