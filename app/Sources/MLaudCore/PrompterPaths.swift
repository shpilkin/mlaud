import Foundation

/// Корень `~/ASR/Prompter/` (или `MLAUD_PROMPTER_DIR` — тогда обе стороны, Swift и worker,
/// считают его корнем `Prompter/`, а не `calls`; этап 4, решение D1).
public struct PrompterPaths: Equatable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `MLAUD_PROMPTER_DIR` из окружения приложения пробрасывается worker'у только если задана:
    /// тесты и снимки работают на временном дереве, обычный запуск — на `~/ASR/Prompter`.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PrompterPaths {
        if let custom = environment["MLAUD_PROMPTER_DIR"], !custom.isEmpty {
            return PrompterPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        return PrompterPaths(root: home.appendingPathComponent("ASR/Prompter", isDirectory: true))
    }

    public var profile: URL { root.appendingPathComponent("profile.md") }
    public var templates: URL { root.appendingPathComponent("templates", isDirectory: true) }
    public var briefs: URL { root.appendingPathComponent("briefs", isDirectory: true) }
    public var calls: URL { root.appendingPathComponent("calls", isDirectory: true) }   // == CallStore root

    public func brief(slug: String) -> URL {
        briefs.appendingPathComponent(slug, isDirectory: true).appendingPathComponent("brief.md")
    }

    public func materials(slug: String) -> URL {
        briefs.appendingPathComponent(slug, isDirectory: true).appendingPathComponent("materials", isDirectory: true)
    }
}
