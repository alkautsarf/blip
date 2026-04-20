// Reads the assistant's last turn from a Claude Code session transcript
// JSONL. Each line is one event; we walk from the end so we don't pay
// for parsing earlier history we don't need.
//
// Two reads are exposed:
//   - lastAssistantText(at:)       — visible reply text only (preview)
//   - lastAssistantFullTurn(at:)   — text + thinking + tool uses (expand)
import Foundation

public enum TranscriptReader {
    public static func lastAssistantText(at path: String) throws -> String? {
        try lastAssistantContent(at: path) { content in
            renderText(blocks: content)
        }
    }

    /// Sums `output_tokens` across every assistant entry in the file.
    /// Used by the token-milestone celebration: every 50K crossed fires
    /// the pet's celebrate animation.
    ///
    /// Streams the file line-by-line via FileHandle to avoid loading
    /// 100s of MB into memory for long-running sessions.
    public static func cumulativeOutputTokens(at path: String) throws -> Int {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var total = 0
        var leftover = Data()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1 << 20)  // 1 MB per pass
            guard !chunk.isEmpty else { return false }
            var buffer = leftover
            buffer.append(chunk)
            leftover.removeAll(keepingCapacity: true)

            var cursor = buffer.startIndex
            while let newline = buffer[cursor...].firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: cursor..<newline)
                cursor = buffer.index(after: newline)
                if let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   entry["type"] as? String == "assistant",
                   let message = entry["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let out = usage["output_tokens"] as? Int {
                    total += out
                }
            }
            // Save partial trailing line for the next chunk.
            if cursor < buffer.endIndex {
                leftover = buffer.subdata(in: cursor..<buffer.endIndex)
            }
            return true
        }) {}
        return total
    }

    /// Full turn rendering for the expand state. Includes:
    ///   - assistant text blocks (verbatim)
    ///   - thinking blocks (with a `[thinking]` header so it's clearly
    ///     not part of the visible reply)
    ///   - tool_use blocks (one-line `[tool: name] input-summary`)
    public static func lastAssistantFullTurn(at path: String) throws -> String? {
        try lastAssistantContent(at: path) { content in
            renderFullTurn(blocks: content)
        }
    }

    // MARK: - Internal

    /// Tail-reads the file from the end with an expanding window so huge
    /// transcripts (100s of MB) don't stall the caller. Starts at 256 KB
    /// — the vast majority of assistant turns fit in a single line that
    /// lives within that tail.
    private static func lastAssistantContent(
        at path: String,
        render: ([[String: Any]]) -> String
    ) throws -> String? {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else { return nil }

        var window: UInt64 = 256 * 1024
        let maxWindow: UInt64 = 32 * 1024 * 1024

        while true {
            let readLen = min(window, fileSize)
            let offset = fileSize - readLen
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(readLen)),
                  let raw = String(data: chunk, encoding: .utf8) else { return nil }

            // Drop partial first line unless we're at file start.
            var lines = raw.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if offset > 0 && lines.count > 0 {
                lines.removeFirst()
            }

            for line in lines.reversed() {
                guard let bytes = line.data(using: .utf8),
                      let entry = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                else { continue }
                guard entry["type"] as? String == "assistant",
                      let message = entry["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]]
                else { continue }
                let rendered = render(content)
                if !rendered.isEmpty { return rendered }
            }

            // Nothing found in this window — expand or give up.
            if readLen == fileSize { return nil }
            if window >= maxWindow { return nil }
            window *= 4
        }
    }

    private static func renderText(blocks: [[String: Any]]) -> String {
        blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n\n")
    }

    private static func renderFullTurn(blocks: [[String: Any]]) -> String {
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    parts.append(text)
                }
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    parts.append("[thinking]\n\(thinking)")
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "?"
                let summary = summarizeToolInput(block["input"])
                parts.append("[tool: \(name)] \(summary)")
            default:
                break
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func summarizeToolInput(_ input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        // Pull the most useful single field per tool. Fall back to first
        // string-valued key.
        for key in ["command", "file_path", "path", "url", "pattern", "description"] {
            if let v = dict[key] as? String, !v.isEmpty {
                return key + ": " + v.prefix(160)
            }
        }
        let first = dict.first { $1 is String }
        if let (k, v) = first, let s = v as? String { return "\(k): \(s.prefix(160))" }
        return ""
    }
}
