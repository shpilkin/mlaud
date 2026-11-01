import Foundation
import Security

/// Доступ внешних агентов к MLaud по MCP (`python -m mlaud_worker.mcp --http`, docs/mcp.md).
/// Здесь — тестируемое: состояние, разбор событий процесса, токен, команда подключения.
public enum AgentAccess {
    public static let defaultPort = 8767
    public static let module = "mlaud_worker.mcp"
    /// Таймаут вызова для openclaw: встреча на час с разделением по спикерам идёт минутами.
    public static let clientTimeoutSec = 900

    public enum State: Equatable {
        case disabled
        case starting
        case listening(port: Int)
        case failed(String)

        public var title: String {
            switch self {
            case .disabled: return "выключен"
            case .starting: return "запускаюсь…"
            case .listening(let port): return "слушаю 127.0.0.1:\(port)"
            case .failed(let reason): return "ошибка — \(reason)"
            }
        }

        public var menuTitle: String { "Агенты (MCP): \(title)" }
    }

    /// Строка stdout процесса сервера.
    public enum Event: Equatable {
        case ready(port: Int)
        case error(String)

        public static func parse(line: String) -> Event? {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let t = obj["t"] as? String
            else { return nil }
            switch t {
            case "ready":
                guard let port = obj["port"] as? Int, port > 0 else { return nil }
                return .ready(port: port)
            case "error":
                return .error(obj["message"] as? String ?? "неизвестная ошибка")
            default:
                return nil
            }
        }
    }

    /// 32 случайных байта в base64url без «=»: 43 символа, безопасно в заголовке и в shell.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes: \(status)")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func isValidToken(_ token: String) -> Bool {
        token.count >= 32 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    public static func endpoint(port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }

    /// Команда, которой сервер добавляется в openclaw (`openclaw mcp add`, проба при сохранении).
    public static func openclawCommand(port: Int, token: String, name: String = "mlaud") -> String {
        "openclaw mcp add \(name) --transport streamable-http --url \(endpoint(port: port))"
            + " --header 'Authorization=Bearer \(token)' --timeout \(clientTimeoutSec)"
    }

    /// Окружение процесса сервера поверх окружения worker'а.
    public static func environment(port: Int, token: String, idleSeconds: Int = 600) -> [String: String] {
        ["MLAUD_MCP_PORT": String(port),
         "MLAUD_MCP_TOKEN": token,
         "MLAUD_MCP_IDLE_SEC": String(idleSeconds),
         "PYTHONUNBUFFERED": "1"]
    }

    // MARK: токен

    public static let tokenAccount = "token"

    /// Токен из хранилища; нет или испорчен — новый, сразу сохранённый.
    public static func loadOrCreateToken(in store: SecretStore) throws -> String {
        if let t = store.secret(for: tokenAccount), isValidToken(t) { return t }
        return try regenerateToken(in: store)
    }

    @discardableResult
    public static func regenerateToken(in store: SecretStore) throws -> String {
        let t = newToken()
        try store.setSecret(t, for: tokenAccount)
        return t
    }

    // MARK: перезапуск

    public enum AfterExit: Equatable {
        case restart(afterSeconds: Double)
        case fail(String)
    }

    /// Что делать, когда процесс сервера завершился сам. Код 2 — ошибка конфигурации
    /// (порт занят, нет токена): повтор не поможет. Иначе — повтор, но не чаще трёх раз
    /// за минуту, чтобы падающий процесс не крутился вечно.
    public static func afterExit(code: Int32, lastError: String?, failuresInLastMinute: Int) -> AfterExit {
        if code == 2 { return .fail(lastError ?? "ошибка конфигурации сервера") }
        if failuresInLastMinute >= 3 {
            return .fail("сервер падает при запуске — подробности в ~/ASR/service/mcp.log")
        }
        return .restart(afterSeconds: 2)
    }
}
