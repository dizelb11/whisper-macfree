import Foundation

/// Клиент демона распознавания. Демон держит модель в памяти и отвечает
/// через Unix-сокет; накладные расходы обмена — единицы миллисекунд.
enum DaemonClient {
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/whisper-local/whisperd.sock")
        .path

    enum Failure: LocalizedError {
        case notRunning
        case daemon(String)

        var errorDescription: String? {
            switch self {
            case .notRunning: "Демон распознавания не запущен"
            case .daemon(let msg): msg
            }
        }
    }

    struct Dictation: Identifiable {
        let id: Int
        let createdAt: String
        let raw: String
        var final: String
        let polished: Bool
        let ms: Int
        /// Что предложила модель — хранится и когда предложение отклонено.
        let proposal: String
        /// Причина отклонения. Пустая — предложение принято.
        let rejected: String
    }

    static func transcribe(wav: URL, polish: Bool) throws -> String {
        let reply = try request(["wav": wav.path, "polish": polish])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
        return (reply["text"] as? String) ?? ""
    }

    static func history(limit: Int = 50) throws -> [Dictation] {
        let reply = try request(["history": ["limit": limit]])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
        let items = (reply["items"] as? [[String: Any]]) ?? []
        return items.compactMap { row in
            guard let id = row["id"] as? Int else { return nil }
            return Dictation(
                id: id,
                createdAt: (row["created_at"] as? String) ?? "",
                raw: (row["raw"] as? String) ?? "",
                final: (row["final"] as? String) ?? "",
                polished: ((row["polished"] as? Int) ?? 0) == 1,
                ms: (row["ms"] as? Int) ?? 0,
                proposal: (row["proposal"] as? String) ?? "",
                rejected: (row["rejected"] as? String) ?? ""
            )
        }
    }

    struct Term: Identifiable, Equatable {
        var id: Int
        /// Как надо: «Claude Code». Уходит в подсказку модели распознавания.
        var canonical: String
        /// Как слышится: «клод кот». Заменяется в готовом тексте.
        /// Пусто — строка работает только как подсказка.
        var alias: String
        var enabled: Bool
    }

    static func terms() throws -> [Term] {
        let reply = try request(["terms": [:]])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
        return ((reply["items"] as? [[String: Any]]) ?? []).compactMap { row in
            guard let id = row["id"] as? Int, let canonical = row["canonical"] as? String
            else { return nil }
            return Term(id: id, canonical: canonical,
                        alias: (row["alias"] as? String) ?? "",
                        enabled: ((row["enabled"] as? Int) ?? 1) == 1)
        }
    }

    @discardableResult
    static func termSave(_ term: Term) throws -> Int {
        var payload: [String: Any] = [
            "canonical": term.canonical, "alias": term.alias, "enabled": term.enabled,
        ]
        if term.id > 0 { payload["id"] = term.id }
        let reply = try request(["term_save": payload])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
        return (reply["id"] as? Int) ?? term.id
    }

    static func termDelete(id: Int) throws {
        let reply = try request(["term_delete": ["id": id]])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
    }

    /// Правка уезжает в демон: пара «было/стало» станет материалом для
    /// словаря, чтобы ту же ошибку больше не повторять.
    static func correct(id: Int, text: String) throws {
        let reply = try request(["correct": ["id": id, "text": text]])
        if let err = reply["error"] as? String { throw Failure.daemon(err) }
    }

    static func isReady() -> Bool {
        (try? request(["ping": true])["ready"] as? Bool) == true
    }

    private static func request(_ payload: [String: Any]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.notRunning }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.notRunning }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            path.withCString { src in
                strcpy(UnsafeMutableRawPointer(raw).assumingMemoryBound(to: CChar.self), src)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) == 0 }
        }
        guard ok else { throw Failure.notRunning }

        var line = try JSONSerialization.data(withJSONObject: payload)
        line.append(0x0A)
        try line.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: sent), buf.count - sent)
                guard n > 0 else { throw Failure.notRunning }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            response.append(contentsOf: chunk[0..<n])
            if response.last == 0x0A { break }
        }
        guard let obj = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            throw Failure.daemon("демон вернул неразборчивый ответ")
        }
        return obj
    }
}
