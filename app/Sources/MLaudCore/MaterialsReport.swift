import Foundation

/// Ответ `python -m mlaud_worker.prompter --materials` (§2.4) — единственный извлекатель
/// и счётчик токенов; Swift своей оценки не делает (решение D4).
public struct MaterialsReport: Equatable, Sendable {
    public var materials: [MaterialInfo]
    public var total: Int
    public var budget: Int
    public var over: [String]

    public init(materials: [MaterialInfo] = [], total: Int = 0, budget: Int = 0, over: [String] = []) {
        self.materials = materials
        self.total = total
        self.budget = budget
        self.over = over
    }

    public static func decode(_ data: Data) throws -> MaterialsReport {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MaterialsReport", code: 1, userInfo: [NSLocalizedDescriptionKey: "не JSON"])
        }
        let materials = (obj["materials"] as? [[String: Any]] ?? []).map {
            MaterialInfo(name: $0["name"] as? String ?? "",
                         kind: $0["kind"] as? String ?? "",
                         tokens: ($0["tokens"] as? NSNumber)?.intValue ?? 0,
                         warning: $0["warning"] as? String)
        }
        return MaterialsReport(materials: materials,
                               total: (obj["total"] as? NSNumber)?.intValue ?? 0,
                               budget: (obj["budget"] as? NSNumber)?.intValue ?? 0,
                               over: obj["over"] as? [String] ?? [])
    }

    /// Та же эвристика, что у worker'а: (число Unicode-скаляров + 2) / 3 — черновой показ
    /// для .md/.txt до ответа процесса.
    public static func estimateTokens(_ text: String) -> Int {
        (text.unicodeScalars.count + 2) / 3
    }
}
