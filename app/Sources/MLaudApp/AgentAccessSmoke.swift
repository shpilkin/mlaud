import Foundation
import MLaudCore

/// Дымовая проверка MCP-сервера из командной строки (см. main.swift): настоящий процесс
/// под `AgentAccessController`, запросы по HTTP с токеном и без. С `hold` после проверок
/// процесс не выходит — чтобы снаружи убить его `kill -9` и убедиться, что сервер ушёл следом.
enum AgentAccessSmoke {
    static func run(python: String, workerDir: String, port: Int, hold: Bool) -> Int32 {
        setlinebuf(stdout)
        let token = AgentAccess.newToken()
        let controller = AgentAccessController(
            logURL: FileManager.default.temporaryDirectory.appendingPathComponent("mlaud-mcp-smoke.log"))
        let pythonURL = URL(fileURLWithPath: python).standardizedFileURL
        let workerURL = URL(fileURLWithPath: workerDir, isDirectory: true).standardizedFileURL
        controller.onStateChanged = { print("state: \(controller.state.title)") }
        controller.start {
            WorkerCommand(
                pythonExecutable: pythonURL, workerDirectory: workerURL, inboxFolder: workerURL,
                additionalPythonPath: (ProcessInfo.processInfo.environment["PYTHONPATH"] ?? "")
                    .split(separator: ":").map { URL(fileURLWithPath: String($0)) },
                extraEnvironment: AgentAccess.environment(port: port, token: token),
                module: AgentAccess.module, moduleArguments: ["--http"])
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if case .listening = controller.state { break }
            if case .failed = controller.state { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        guard case .listening(let actual) = controller.state else {
            print("FAIL: сервер не поднялся: \(controller.state.title)")
            return 1
        }
        var ok = true
        let list = post(port: actual, token: token, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let names = ((list.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        print("tools/list \(list.code): \(names.joined(separator: ","))")
        ok = ok && list.code == 200 && names.contains("transcribe")
        let denied = post(port: actual, token: "wrong", body: #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        print("чужой токен: \(denied.code)")
        ok = ok && denied.code == 401
        print(ok ? "OK" : "FAIL")
        if hold && ok {
            print("HOLD pid \(getpid())")
            RunLoop.main.run()
        }
        controller.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        return ok ? 0 : 1
    }

    private static func post(port: Int, token: String, body: String) -> (code: Int, json: [String: Any]?) {
        var request = URLRequest(url: URL(string: AgentAccess.endpoint(port: port))!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        var result: (Int, [String: Any]?) = (0, nil)
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            result = (code, json)
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
