// Purpose: Shared LLM HTTP transport for all backends (OpenAI, OpenRouter, ChatGPT/WHAM, Ollama, LM Studio, Custom LLM)
// Created: 2026-05-27

import Foundation
import MuesliCore
import os

// MARK: - Shared types

struct LLMMessage {
    enum Role: String {
        case system, user, assistant
    }
    let role: Role
    let content: String
}

enum LLMBackendError: LocalizedError {
    case backendFailed(backend: String, statusCode: Int?, message: String)
    case emptyResponse(backend: String)
    case requestFailed(backend: String, underlying: Error)
    case notConfigured(backend: String)

    var errorDescription: String? {
        switch self {
        case let .backendFailed(backend, statusCode, message):
            let statusText = statusCode.map { " Status \($0)." } ?? ""
            return "\(backend) could not respond.\(statusText) \(message)"
        case let .emptyResponse(backend):
            return "\(backend) returned an empty response."
        case let .requestFailed(backend, underlying):
            return "\(backend) could not be reached. \(underlying.localizedDescription)"
        case let .notConfigured(backend):
            return "\(backend) is not configured. Please add an API key in Settings."
        }
    }
}

// MARK: - LLMBackendClient

enum LLMBackendClient {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "LLMBackend")

    // MARK: Constants

    private static let openAIResponsesURL = URL(string: "https://api.openai.com/v1/responses")!
    private static let openAIChatURL = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private static let whamURL = URL(string: "https://chatgpt.com/backend-api/wham/responses")!
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!
    private static let defaultLMStudioBaseURL = URL(string: "http://localhost:1234")!
    private static let defaultOpenAIModel = "gpt-5.4-mini"
    private static let defaultOpenRouterModel = "stepfun/step-3.5-flash:free"
    private static let defaultChatGPTModel = "gpt-5.4-mini"
    private static let defaultOllamaModel = "qwen3.5"

    // MARK: - Public API

    /// Send messages to the configured LLM backend and return the response text.
    ///
    /// - Parameters:
    ///   - messages: The conversation messages to send.
    ///   - config: App configuration containing backend selection and credentials.
    ///   - timeout: Request timeout interval.
    ///   - maxTokens: Maximum tokens for the response. When nil, backends that require it
    ///     will use their own defaults (e.g. Anthropic defaults to 4096).
    /// - Returns: The generated text response.
    static func send(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let backend = (config.meetingSummaryBackend.isEmpty
            ? MeetingSummaryBackendOption.chatGPT.backend
            : config.meetingSummaryBackend).lowercased()

        if backend == MeetingSummaryBackendOption.chatGPT.backend {
            return try await sendWithChatGPT(messages: messages, config: config, timeout: timeout)
        }
        if backend == MeetingSummaryBackendOption.openRouter.backend {
            return try await sendWithOpenRouter(messages: messages, config: config, timeout: timeout, maxTokens: maxTokens)
        }
        if backend == MeetingSummaryBackendOption.ollama.backend {
            return try await sendWithOllama(messages: messages, config: config, timeout: timeout, maxTokens: maxTokens)
        }
        if backend == MeetingSummaryBackendOption.lmStudio.backend {
            return try await sendWithLMStudio(messages: messages, config: config, timeout: timeout, maxTokens: maxTokens)
        }
        if backend == MeetingSummaryBackendOption.customLLM.backend {
            return try await sendWithCustomLLM(messages: messages, config: config, timeout: timeout, maxTokens: maxTokens)
        }
        return try await sendWithOpenAI(messages: messages, config: config, timeout: timeout, maxTokens: maxTokens)
    }

    // MARK: - URL resolution (public)

    static func resolveLMStudioURL(config: AppConfig) -> URL? {
        let rawURL = config.lmStudioURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolveEndpointURL(
            rawURL.isEmpty ? defaultLMStudioBaseURL.absoluteString : rawURL,
            endpointSuffix: "v1/chat/completions"
        )
    }

    static func resolveCustomLLMURL(config: AppConfig, format: CustomLLMFormat) -> URL? {
        let rawURL = config.customLLMURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultURL: String
        let endpointSuffix: String
        switch format {
        case .openAI:
            defaultURL = "http://localhost:8080/v1/chat/completions"
            endpointSuffix = "v1/chat/completions"
        case .anthropic:
            defaultURL = "https://api.anthropic.com/v1/messages"
            endpointSuffix = "v1/messages"
        }
        return resolveEndpointURL(rawURL.isEmpty ? defaultURL : rawURL, endpointSuffix: endpointSuffix)
    }

    static func customLLMRequiresAPIKey(config: AppConfig) -> Bool {
        (CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI) == .anthropic
    }

    static func lmStudioHasRequiredSettings(config: AppConfig) -> Bool {
        !config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func customLLMHasRequiredSettings(config: AppConfig) -> Bool {
        let model = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !model.isEmpty && (!customLLMRequiresAPIKey(config: config) || !apiKey.isEmpty)
    }

    // MARK: - Per-backend send methods

    private static func sendWithOpenAI(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey
        guard !apiKey.isEmpty else {
            throw LLMBackendError.notConfigured(backend: "OpenAI")
        }

        let input: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": config.openAIModel.isEmpty ? defaultOpenAIModel : config.openAIModel,
            "input": input,
            "reasoning": ["effort": "low"],
            "text": ["verbosity": "low"],
        ]
        if let maxTokens {
            body["max_output_tokens"] = maxTokens
        }

        var request = URLRequest(url: openAIResponsesURL)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenAI")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenAIText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw LLMBackendError.backendFailed(backend: "OpenAI", statusCode: nil, message: message)
                }
                throw LLMBackendError.emptyResponse(backend: "OpenAI")
            }
            return text
        } catch {
            throw backendRequestError(backend: "OpenAI", error: error)
        }
    }

    private static func sendWithOpenRouter(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let apiKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey
        guard !apiKey.isEmpty else {
            throw LLMBackendError.notConfigured(backend: "OpenRouter")
        }

        let configuredModel = config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? defaultOpenRouterModel : configuredModel
        let chatMessages: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
        ]
        if let maxTokens {
            body["max_tokens"] = maxTokens
        }

        var request = URLRequest(url: openRouterURL)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(AppIdentity.displayName, forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "OpenRouter")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw LLMBackendError.backendFailed(backend: "OpenRouter", statusCode: nil, message: message)
                }
                throw LLMBackendError.emptyResponse(backend: "OpenRouter")
            }
            return text
        } catch {
            throw backendRequestError(backend: "OpenRouter", error: error)
        }
    }

    private static func sendWithChatGPT(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval
    ) async throws -> String {
        do {
            let text = try await callWHAM(
                messages: messages,
                model: config.chatGPTModel.isEmpty ? defaultChatGPTModel : config.chatGPTModel
            )
            guard let text, !text.isEmpty else {
                throw LLMBackendError.emptyResponse(backend: "ChatGPT")
            }
            return text
        } catch {
            fputs("[llm-backend] ChatGPT failed: \(error)\n", stderr)
            throw backendRequestError(backend: "ChatGPT", error: error)
        }
    }

    private static func sendWithOllama(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let baseURLString = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL
        if baseURLString.isEmpty {
            baseURL = defaultOllamaBaseURL
        } else {
            guard let url = URL(string: baseURLString) else {
                throw LLMBackendError.backendFailed(backend: "Ollama", statusCode: nil, message: "Invalid Ollama URL: \(baseURLString)")
            }
            baseURL = url
        }
        let chatURL = baseURL.appendingPathComponent("api/chat")

        let configuredModel = config.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? defaultOllamaModel : configuredModel
        let chatMessages: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "stream": false,
        ]
        if let maxTokens {
            body["options"] = ["num_predict": maxTokens]
        }

        var request = URLRequest(url: chatURL)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Ollama")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let text = message["content"] as? String,
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw LLMBackendError.backendFailed(backend: "Ollama", statusCode: nil, message: message)
                }
                throw LLMBackendError.emptyResponse(backend: "Ollama")
            }
            return text
        } catch {
            throw backendRequestError(backend: "Ollama", error: error)
        }
    }

    private static func sendWithLMStudio(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        guard let requestURL = resolveLMStudioURL(config: config) else {
            throw LLMBackendError.backendFailed(backend: "LM Studio", statusCode: nil, message: "Invalid LM Studio URL: \(config.lmStudioURL)")
        }
        let configuredModel = config.lmStudioModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredModel.isEmpty else {
            throw LLMBackendError.backendFailed(
                backend: "LM Studio",
                statusCode: nil,
                message: "No model selected. Select an LM Studio model in Settings."
            )
        }
        return try await sendViaChatCompletions(
            backend: "LM Studio",
            requestURL: requestURL,
            apiKey: "",
            model: configuredModel,
            messages: messages,
            timeout: timeout,
            maxTokens: maxTokens
        )
    }

    private static func sendWithCustomLLM(
        messages: [LLMMessage],
        config: AppConfig,
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        guard let requestURL = resolveCustomLLMURL(config: config, format: format) else {
            throw LLMBackendError.backendFailed(backend: "Custom LLM", statusCode: nil, message: "Invalid custom URL: \(config.customLLMURL)")
        }
        let configuredModel = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configuredModel.isEmpty else {
            throw LLMBackendError.backendFailed(
                backend: "Custom LLM",
                statusCode: nil,
                message: "No model selected. Enter a model in Settings."
            )
        }
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if customLLMRequiresAPIKey(config: config) && apiKey.isEmpty {
            throw LLMBackendError.backendFailed(
                backend: "Custom LLM",
                statusCode: nil,
                message: "Enter an API key for the selected Custom LLM format."
            )
        }

        switch format {
        case .openAI:
            return try await sendViaChatCompletions(
                backend: "Custom LLM",
                requestURL: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                messages: messages,
                timeout: timeout,
                maxTokens: maxTokens
            )
        case .anthropic:
            return try await sendViaAnthropicMessages(
                backend: "Custom LLM",
                requestURL: requestURL,
                apiKey: apiKey,
                model: configuredModel,
                messages: messages,
                timeout: timeout,
                maxTokens: maxTokens
            )
        }
    }

    // MARK: - Shared transport primitives

    /// Send messages via an OpenAI-compatible chat completions endpoint.
    private static func sendViaChatCompletions(
        backend: String,
        requestURL: URL,
        apiKey: String,
        model: String,
        messages: [LLMMessage],
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let isOpenAI = requestURL.host?.contains("openai.com") == true
        let chatMessages: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
        ]
        if let maxTokens {
            // OpenAI newer models require max_completion_tokens; other providers use max_tokens
            body[isOpenAI ? "max_completion_tokens" : "max_tokens"] = maxTokens
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: backend)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractOpenRouterText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw LLMBackendError.backendFailed(backend: backend, statusCode: nil, message: message)
                }
                throw LLMBackendError.emptyResponse(backend: backend)
            }
            return text
        } catch {
            throw backendRequestError(backend: backend, error: error)
        }
    }

    /// Send messages via the Anthropic Messages API format.
    private static func sendViaAnthropicMessages(
        backend: String,
        requestURL: URL,
        apiKey: String,
        model: String,
        messages: [LLMMessage],
        timeout: TimeInterval,
        maxTokens: Int?
    ) async throws -> String {
        let systemContent = messages.first(where: { $0.role == .system })?.content ?? ""
        let nonSystemMessages: [[String: Any]] = messages
            .filter { $0.role != .system }
            .map { ["role": $0.role.rawValue, "content": $0.content] }

        // Anthropic requires max_tokens; default to 4096 when caller doesn't specify
        let effectiveMaxTokens = maxTokens ?? 4096
        var body: [String: Any] = [
            "model": model,
            "max_tokens": effectiveMaxTokens,
            "messages": nonSystemMessages,
        ]
        if !systemContent.isEmpty {
            body["system"] = systemContent
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: backend)
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = extractAnthropicText(from: json),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw LLMBackendError.backendFailed(backend: backend, statusCode: nil, message: message)
                }
                throw LLMBackendError.emptyResponse(backend: backend)
            }
            return text
        } catch {
            throw backendRequestError(backend: backend, error: error)
        }
    }

    /// Call the WHAM streaming API and collect the full response text.
    /// Handles multi-turn messages: system messages become `instructions`, non-system become `input` array.
    private static func callWHAM(messages: [LLMMessage], model: String) async throws -> String? {
        let (token, accountId) = try await ChatGPTAuthManager.shared.validAccessToken()

        let systemContent = messages.first(where: { $0.role == .system })?.content ?? ""
        let nonSystemMessages = messages.filter { $0.role != .system }
        let inputMessages: [[String: Any]] = nonSystemMessages.map { msg in
            [
                "role": msg.role == .user ? "user" : "assistant",
                "content": [["type": "input_text", "text": msg.content] as [String: Any]],
            ] as [String: Any]
        }

        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "input": inputMessages,
        ]
        if !systemContent.isEmpty {
            body["instructions"] = systemContent
        }
        // Note: WHAM does not support max_output_tokens — silently ignored

        var request = URLRequest(url: whamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard httpStatus == 200 else {
            // Collect error body
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            let message = extractErrorMessage(from: errorData) ?? String(data: errorData, encoding: .utf8) ?? "(unknown)"
            fputs("[llm-backend] ChatGPT WHAM: HTTP \(httpStatus): \(String(message.prefix(500)))\n", stderr)
            throw LLMBackendError.backendFailed(backend: "ChatGPT", statusCode: httpStatus, message: message)
        }

        // Parse SSE stream: collect text deltas from response.output_text.delta events
        var fullText = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            if jsonStr == "[DONE]" { break }
            guard let data = jsonStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            // Check for output_text.done with full text
            if let outputText = json["output_text"] as? String, !outputText.isEmpty {
                fullText = outputText
            }

            // Check for streaming delta
            if let type = json["type"] as? String, type == "response.output_text.delta",
               let delta = json["delta"] as? String {
                fullText += delta
            }
        }

        fputs("[llm-backend] ChatGPT WHAM: collected \(fullText.count) chars\n", stderr)
        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response extractors

    private static func extractOpenAIText(from payload: [String: Any]) -> String? {
        if let outputText = payload["output_text"] as? String, !outputText.isEmpty {
            return outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let output = payload["output"] as? [[String: Any]] ?? []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for entry in content {
                if let text = entry["text"] as? String, !text.isEmpty {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return nil
    }

    /// Extract text from a chat completions response (OpenRouter and OpenAI-compatible).
    /// Handles both string and array `content` field.
    private static func extractOpenRouterText(from payload: [String: Any]) -> String? {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        guard let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let content = message["content"] as? [[String: Any]] {
            let parts = content.compactMap { entry -> String? in
                guard (entry["type"] as? String) == "text", let text = entry["text"] as? String, !text.isEmpty else {
                    return nil
                }
                return text
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func extractAnthropicText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { entry -> String? in
            guard (entry["type"] as? String) == "text",
                  let text = entry["text"] as? String,
                  !text.isEmpty else {
                return nil
            }
            return text
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - HTTP helpers

    private static func validateHTTPResponse(_ response: URLResponse, data: Data, backend: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = extractErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw LLMBackendError.backendFailed(
                backend: backend,
                statusCode: httpResponse.statusCode,
                message: String(message.prefix(800))
            )
        }
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = error["code"] as? String, !code.isEmpty {
                return code
            }
            return String(describing: error)
        }

        if let message = json["message"] as? String, !message.isEmpty {
            return message
        }

        if let detail = json["detail"] as? String, !detail.isEmpty {
            return detail
        }

        return nil
    }

    private static func backendRequestError(backend: String, error: Error) -> Error {
        if error is LLMBackendError {
            return error
        }
        return LLMBackendError.requestFailed(backend: backend, underlying: error)
    }

    // MARK: - URL resolution helpers

    private static func resolveEndpointURL(_ rawURL: String, endpointSuffix: String) -> URL? {
        guard var components = URLComponents(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }

        let suffixParts = endpointSuffix.split(separator: "/").map(String.init)
        var pathParts = components.path.split(separator: "/").map(String.init)

        if pathParts.isEmpty {
            pathParts = suffixParts
        } else if pathParts.last == suffixParts.first {
            pathParts = Array(pathParts.dropLast()) + suffixParts
        } else if !isCompleteEndpointPath(pathParts, endpointSuffixParts: suffixParts) {
            pathParts.append(contentsOf: suffixParts)
        }

        components.path = "/" + pathParts.joined(separator: "/")
        return components.url
    }

    private static func isCompleteEndpointPath(_ pathParts: [String], endpointSuffixParts suffixParts: [String]) -> Bool {
        if pathParts.suffix(suffixParts.count).elementsEqual(suffixParts) {
            return true
        }
        if suffixParts == ["v1", "chat", "completions"] {
            return pathParts.suffix(2).elementsEqual(["chat", "completions"])
        }
        if suffixParts == ["v1", "messages"] {
            return pathParts.count >= suffixParts.count && pathParts.last == "messages"
        }
        return false
    }
}
