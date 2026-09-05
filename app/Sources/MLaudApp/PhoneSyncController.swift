import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import MLaudCore
import MLaudSync

/// Приём записей с iPhone.
///
/// Заменяет транзит через iCloud: телефон находит Mac по Bonjour и передаёт файл
/// напрямую, зашифрованным каналом на общем секрете. Принятое кладётся в ту же
/// папку inbox, за которой уже следит приложение, — конвейер обработки не меняется.
final class PhoneSyncController {
    enum State: Equatable {
        case disabled
        case starting
        case listening(port: UInt16)
        case failed(String)

        var menuTitle: String {
            switch self {
            case .disabled: return "iPhone: приём выключен"
            case .starting: return "iPhone: запускаюсь…"
            case .listening: return "iPhone: жду записи"
            case .failed(let reason): return "iPhone: ошибка — \(reason)"
            }
        }
    }

    struct Received: Equatable {
        let name: String
        let at: Date
    }

    private(set) var state: State = .disabled
    private(set) var lastReceived: Received?

    /// Вызывается после успешного приёма — снаружи это повод сразу запустить обработку.
    var onReceived: ((String) -> Void)?
    var onStateChanged: (() -> Void)?

    private let pairingStore: PhoneSyncPairingStore
    private var server: SyncServer?

    init(serviceDirectory: URL) {
        pairingStore = PhoneSyncPairingStore(
            url: serviceDirectory.appendingPathComponent("sync/pairing.json")
        )
    }

    // MARK: - Жизненный цикл

    /// Поднимает приёмник. `inbox` — папка, за которой следит приложение;
    /// без неё сервер отвечает телефону «приём не настроен», а не молчит.
    func start(inbox: URL?, serviceDirectory: URL) {
        stop()
        state = .starting
        onStateChanged?()

        let staging = (inbox ?? serviceDirectory).appendingPathComponent(".incoming")
        // Брошенные куски убираем до старта: сервер сам их не тронет — он знает
        // только про те, за которыми пришли.
        DispatchQueue.global(qos: .utility).async {
            PhoneSyncStaging.sweep(directory: staging)
        }

        do {
            let pairing = try pairingStore.loadOrCreate()
            let configuration = SyncServer.Configuration(
                serverID: pairing.serverID,
                serverName: Host.current().localizedName ?? "Mac",
                psk: pairing.psk,
                inboxDirectory: inbox,
                // Промежуточная папка — ВНУТРИ inbox и скрытая. Так гарантирован
                // один том с итоговым файлом, а значит подмена атомарна: наблюдатель
                // увидит сразу целый файл. Скрытые каталоги и Swift-сканер, и
                // Python-воркер пропускают.
                stagingDirectory: staging,
                ledgerURL: serviceDirectory.appendingPathComponent("sync/received.json")
            )
            let server = SyncServer(configuration: configuration)
            server.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
            try server.start()
            self.server = server
        } catch {
            state = .failed("\(error)")
            onStateChanged?()
        }
    }

    func stop() {
        server?.stop()
        server = nil
        state = .disabled
        onStateChanged?()
    }

    private func handle(_ event: SyncServer.Event) {
        switch event {
        case .listening(let port):
            state = .listening(port: port)
        case .received(let name, _, _):
            lastReceived = Received(name: name, at: Date())
            onReceived?(name)
        case .failed(let reason):
            state = .failed(reason)
        case .connected, .rejected:
            break
        }
        onStateChanged?()
    }

    // MARK: - Сопряжение

    var pairing: PhoneSyncPairing? { pairingStore.load() }

    /// Строка, которая уезжает в QR-код.
    func pairingCode() throws -> String {
        let pairing = try pairingStore.loadOrCreate()
        return PairingCode.encode(PairedMac(
            serverID: pairing.serverID,
            name: Host.current().localizedName ?? "Mac",
            psk: pairing.psk
        ))
    }

    /// Тот же секрет для ручного ввода — если камера недоступна.
    func manualCode() throws -> String {
        let pairing = try pairingStore.loadOrCreate()
        return PairingCode.manualCode(for: PairedMac(
            serverID: pairing.serverID, name: "", psk: pairing.psk
        ))
    }

    /// Новый секрет: связанные телефоны придётся сопрягать заново.
    func regeneratePairing() throws {
        try pairingStore.regenerate()
    }

    static func qrImage(for text: String, side: CGFloat = 240) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Средняя коррекция ошибок: код смотрят с экрана в паре сантиметров,
        // запас на грязь и блики не нужен, а плотность ниже — сканируется быстрее.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
