import Foundation

/// Runs the whole "recording finished" -> "document ready" chain.
/// Everything is synchronous/sequential and runs off the main thread.
final class Pipeline {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    func run(recordingPath: String, statusLog: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                statusLog("Извлекаю аудио…")
                let audioPath = try self.extractAudio(from: recordingPath)

                statusLog("Отправляю на транскрибацию (Deepgram)…")
                let transcript = try self.transcribe(audioPath: audioPath)

                statusLog("Анализирую транскрипт (Claude)…")
                let document = try self.analyze(transcript: transcript)

                statusLog("Сохраняю документ…")
                let outPath = try self.saveDocument(document, sourceRecording: recordingPath)

                statusLog("Готово: \(outPath)")
                NSWorkspaceOpener.reveal(path: outPath)
            } catch {
                statusLog("Ошибка пайплайна: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Step 1: ffmpeg audio extraction

    private func extractAudio(from videoPath: String) throws -> String {
        let audioPath = (videoPath as NSString).deletingPathExtension + ".m4a"
        if FileManager.default.fileExists(atPath: audioPath) {
            try? FileManager.default.removeItem(atPath: audioPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try which("ffmpeg"))
        process.arguments = [
            "-y", "-i", videoPath,
            "-vn", "-acodec", "aac", "-b:a", "128k",
            audioPath
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? "unknown ffmpeg error"
            throw PipelineError.step("ffmpeg failed: \(errText)")
        }
        return audioPath
    }

    private func which(_ tool: String) throws -> String {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw PipelineError.step("\(tool) not found — install with `brew install \(tool)`")
    }

    // MARK: - Step 2: Deepgram transcription

    /// Deepgram's pre-recorded endpoint is synchronous (no upload+poll dance): the file goes
    /// straight in the request body and the response holds the finished transcript.
    private func transcribe(audioPath: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: audioPath))

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "detect_language", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "paragraphs", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        // Long meetings can take several minutes to transcribe; the request stays open
        // the whole time since this endpoint is synchronous, so use a generous timeout.
        request.timeoutInterval = 3600
        request.setValue("Token \(config.deepgramKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (respData, response) = try syncRequest(request)
        try checkHTTP(response, respData, context: "Deepgram transcribe")
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any]
        return try formatDeepgramTranscript(json)
    }

    private func formatDeepgramTranscript(_ json: [String: Any]?) throws -> String {
        guard let results = json?["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternative = channels.first?["alternatives"] as? [[String: Any]],
              let firstAlt = alternative.first else {
            throw PipelineError.step("Deepgram transcribe: unexpected response shape")
        }

        if let paragraphs = firstAlt["paragraphs"] as? [String: Any],
           let transcript = paragraphs["transcript"] as? String,
           !transcript.isEmpty {
            return transcript
        }
        return (firstAlt["transcript"] as? String) ?? ""
    }

    // MARK: - Step 3: Claude analysis

    private func analyze(transcript: String) throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(config.anthropicKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": "claude-sonnet-5",
            "max_tokens": 8192,
            "system": PromptTemplates.systemPrompt(),
            "messages": [["role": "user", "content": transcript]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try syncRequest(request)
        try checkHTTP(response, respData, context: "Claude analyze")
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw PipelineError.step("Claude response missing content text")
        }
        return text
    }

    // MARK: - Step 4: save document

    private func saveDocument(_ markdown: String, sourceRecording: String) throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: config.outputFolder, withIntermediateDirectories: true)

        let baseName = (sourceRecording as NSString).lastPathComponent
            .replacingOccurrences(of: (sourceRecording as NSString).pathExtension, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let mdPath = "\(config.outputFolder)/\(baseName).md"
        try markdown.write(toFile: mdPath, atomically: true, encoding: .utf8)

        if let pandoc = try? which("pandoc") {
            let docxPath = "\(config.outputFolder)/\(baseName).docx"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pandoc)
            process.arguments = [mdPath, "-o", docxPath]
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0, fm.fileExists(atPath: docxPath) {
                return docxPath
            }
        }
        return mdPath
    }

    // MARK: - HTTP helpers

    private func syncRequest(_ request: URLRequest) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>!
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(PipelineError.step("empty response"))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try result.get()
    }

    private func checkHTTP(_ response: URLResponse, _ data: Data, context: String) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw PipelineError.step("\(context) failed (HTTP \(code)): \(bodyText)")
        }
    }
}

enum PipelineError: LocalizedError {
    case step(String)
    var errorDescription: String? {
        switch self {
        case .step(let message): return message
        }
    }
}
