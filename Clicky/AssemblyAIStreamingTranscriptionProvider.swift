//
//  AssemblyAIStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming AI transcription provider backed by AssemblyAI's websocket API.
//

import AVFoundation
import Foundation

struct AssemblyAIStreamingTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class AssemblyAIStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    /// URL for the Cloudflare Worker endpoint that returns a short-lived
    /// AssemblyAI streaming token. The real API key never leaves the server.
    private static let tokenProxyURL = "https://clicky-proxy.clicky-proxy-nana.workers.dev/transcribe-token"

    /// Server-side token lifetime is 480s; treat ours as fresh for slightly
    /// less so a press never races the token's actual expiry.
    private static let cachedTokenFreshForSeconds: TimeInterval = 420
    /// Cached token shared across presses. Fetching one costs a Cloudflare
    /// worker round-trip, which used to sit on the key-down critical path
    /// (hundreds of ms warm, seconds when the worker was cold).
    private static let tokenCacheLock = NSLock()
    private static var cachedTemporaryToken: String?
    private static var cachedTokenFetchedAt = Date.distantPast

    let displayName = "AssemblyAI"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    /// Single long-lived URLSession shared across all streaming sessions.
    /// Creating and invalidating a URLSession per session corrupts the OS
    /// connection pool and causes "Socket is not connected" errors after
    /// a few rapid reconnections to the same host.
    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    init() {
        // Prefetch a token at app launch so the first press only needs the
        // websocket handshake, and keep it fresh in the background afterwards.
        Task { [weak self] in
            _ = try? await self?.fetchTemporaryToken()
        }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Reuse a fresh cached token when possible; only pays the worker
        // round-trip when the cache is empty or stale.
        let temporaryToken = try await fetchTemporaryToken()
        print("🎙️ AssemblyAI: using temporary token (\(temporaryToken.prefix(20))...)")

        let session = AssemblyAIStreamingTranscriptionSession(
            apiKey: nil,
            temporaryToken: temporaryToken,
            urlSession: sharedWebSocketURLSession,
            keyterms: keyterms,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        do {
            try await session.open()
            return session
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw error
            }
            // The first attempt may have failed because of a stale token —
            // invalidate and retry once with a fresh one.
            print("🎙️ AssemblyAI: websocket open failed (\(error)) — retrying once with a fresh token")
            Self.invalidateCachedToken()
            let freshToken = try await requestTemporaryToken()
            Self.storeCachedToken(freshToken)

            let retrySession = AssemblyAIStreamingTranscriptionSession(
                apiKey: nil,
                temporaryToken: freshToken,
                urlSession: sharedWebSocketURLSession,
                keyterms: keyterms,
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
            try await retrySession.open()
            return retrySession
        }
    }

    // MARK: - Token Cache

    private func fetchTemporaryToken() async throws -> String {
        if let freshToken = Self.freshCachedToken() {
            print("🎙️ AssemblyAI: reusing cached temporary token")
            return freshToken
        }

        do {
            let token = try await requestTemporaryToken()
            Self.storeCachedToken(token)
            scheduleBackgroundTokenRefresh(afterSeconds: Self.cachedTokenFreshForSeconds)
            return token
        } catch {
            scheduleBackgroundTokenRefresh(afterSeconds: 30)
            throw error
        }
    }

    private func scheduleBackgroundTokenRefresh(afterSeconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(afterSeconds * 1_000_000_000))
            _ = try? await self?.fetchTemporaryToken()
        }
    }

    private static func freshCachedToken() -> String? {
        tokenCacheLock.lock()
        defer { tokenCacheLock.unlock() }
        guard let cachedTemporaryToken,
              Date().timeIntervalSince(cachedTokenFetchedAt) < cachedTokenFreshForSeconds else {
            return nil
        }
        return cachedTemporaryToken
    }

    private static func storeCachedToken(_ token: String) {
        tokenCacheLock.lock()
        cachedTemporaryToken = token
        cachedTokenFetchedAt = Date()
        tokenCacheLock.unlock()
    }

    private static func invalidateCachedToken() {
        tokenCacheLock.lock()
        cachedTemporaryToken = nil
        cachedTokenFetchedAt = .distantPast
        tokenCacheLock.unlock()
    }

    /// Calls the Cloudflare Worker to get a short-lived AssemblyAI token.
    /// Never called directly on the press path — goes through the cache.
    private func requestTemporaryToken() async throws -> String {
        var request = URLRequest(url: URL(string: Self.tokenProxyURL)!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Failed to fetch AssemblyAI token (HTTP \(statusCode)): \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "Invalid token response from proxy."
            )
        }

        return token
    }
}

private final class AssemblyAIStreamingTranscriptionSession: NSObject, BuddyStreamingTranscriptionSession {
    private struct MessageEnvelope: Decodable {
        let type: String
    }

    private struct TurnMessage: Decodable {
        let type: String
        let transcript: String?
        let turn_order: Int?
        let end_of_turn: Bool?
        let turn_is_formatted: Bool?
    }

    private struct ErrorMessage: Decodable {
        let type: String
        let error: String?
        let message: String?
    }

    private struct StoredTurnTranscript {
        var transcriptText: String
        var isFormatted: Bool
    }

    private static let websocketBaseURLString = "wss://streaming.assemblyai.com/v3/ws"
    private static let targetSampleRate = 16_000.0
    /// How long to wait after ForceEndpoint for AssemblyAI's end-of-turn reply
    /// before submitting the best-available transcript anyway. Push-to-talk is
    /// bounded by key release, so a long silence-detection wait just adds
    /// latency — 0.6s catches the normal reply without stalling the pipeline.
    private static let explicitFinalTranscriptGracePeriodSeconds = 0.6
    /// How long to wait for AssemblyAI's initial "Begin" before failing the
    /// connect (previously unbounded — a silent websocket wedged dictation
    /// until app restart).
    private static let readyTimeoutSeconds: TimeInterval = 4

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 2.8

    private let apiKey: String?
    private let temporaryToken: String?
    private let keyterms: [String]
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.assemblyai.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)
    private let urlSession: URLSession

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeoutWorkItem: DispatchWorkItem?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var activeTurnOrder: Int?
    private var activeTurnTranscriptText = ""
    private var storedTurnTranscriptsByOrder: [Int: StoredTurnTranscript] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        apiKey: String?,
        temporaryToken: String?,
        urlSession: URLSession,
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.apiKey = apiKey
        self.temporaryToken = temporaryToken
        self.urlSession = urlSession
        self.keyterms = keyterms
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let websocketURL = try Self.makeWebsocketURL(
            temporaryToken: temporaryToken,
            keyterms: keyterms
        )

        var websocketRequest = URLRequest(url: websocketURL)
        if let apiKey {
            websocketRequest.setValue(apiKey, forHTTPHeaderField: "Authorization")
        }

        let webSocketTask = urlSession.webSocketTask(with: websocketRequest)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            // Fail after readyTimeoutSeconds if the server never sends "Begin",
            // so a silent websocket can't wedge every future press.
            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.resolveReadyContinuationIfNeeded(with: .failure(
                    AssemblyAIStreamingTranscriptionProviderError(
                        message: "Timed out waiting for the AssemblyAI session to start"
                    )
                ))
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
            }

            stateQueue.async {
                self.readyContinuation = continuation
                self.readyTimeoutWorkItem = timeoutWorkItem
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyTimeoutSeconds, execute: timeoutWorkItem)
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.data(audioPCM16Data)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage(["type": "ForceEndpoint"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        sendJSONMessage(["type": "Terminate"])
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(MessageEnvelope.self, from: messageData)

            switch envelope.type.lowercased() {
            case "begin":
                resolveReadyContinuationIfNeeded(with: .success(()))
            case "turn":
                let turnMessage = try JSONDecoder().decode(TurnMessage.self, from: messageData)
                handleTurnMessage(turnMessage)
            case "termination":
                resolveReadyContinuationIfNeeded(with: .success(()))
                stateQueue.async {
                    if self.isAwaitingExplicitFinalTranscript && !self.hasDeliveredFinalTranscript {
                        self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
                    }
                }
            case "error":
                let errorMessage = try JSONDecoder().decode(ErrorMessage.self, from: messageData)
                let messageText = errorMessage.error ?? errorMessage.message ?? "AssemblyAI returned an error."
                failSession(with: AssemblyAIStreamingTranscriptionProviderError(message: messageText))
            default:
                break
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleTurnMessage(_ turnMessage: TurnMessage) {
        let transcriptText = turnMessage.transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        stateQueue.async {
            let turnOrder = turnMessage.turn_order
                ?? self.activeTurnOrder
                ?? ((self.storedTurnTranscriptsByOrder.keys.max() ?? -1) + 1)

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.activeTurnOrder = nil
                self.activeTurnTranscriptText = ""
                self.storeTurnTranscript(
                    transcriptText,
                    forTurnOrder: turnOrder,
                    isFormatted: turnMessage.turn_is_formatted == true
                )
            } else {
                self.activeTurnOrder = turnOrder
                self.activeTurnTranscriptText = transcriptText
            }

            let fullTranscriptText = self.composeFullTranscript()
            self.latestTranscriptText = fullTranscriptText

            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            guard self.isAwaitingExplicitFinalTranscript else { return }

            if turnMessage.end_of_turn == true || turnMessage.turn_is_formatted == true {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func storeTurnTranscript(
        _ transcriptText: String,
        forTurnOrder turnOrder: Int,
        isFormatted: Bool
    ) {
        guard !transcriptText.isEmpty else { return }

        if let existingTurnTranscript = storedTurnTranscriptsByOrder[turnOrder] {
            if existingTurnTranscript.isFormatted && !isFormatted {
                return
            }
        }

        storedTurnTranscriptsByOrder[turnOrder] = StoredTurnTranscript(
            transcriptText: transcriptText,
            isFormatted: isFormatted
        )
    }

    private func composeFullTranscript() -> String {
        let committedTranscriptSegments = storedTurnTranscriptsByOrder
            .sorted(by: { $0.key < $1.key })
            .map(\.value.transcriptText)
            .filter { !$0.isEmpty }

        var transcriptSegments = committedTranscriptSegments

        let trimmedActiveTurnTranscriptText = activeTurnTranscriptText
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedActiveTurnTranscriptText.isEmpty {
            transcriptSegments.append(trimmedActiveTurnTranscriptText)
        }

        return transcriptSegments.joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
        sendJSONMessage(["type": "Terminate"])
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[AssemblyAI] ⚠️ WebSocket error during active session, delivering partial transcript as fallback: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }
            print("[AssemblyAI] ❌ Session failed with error: \(error.localizedDescription)")

            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true
            self.readyTimeoutWorkItem?.cancel()
            self.readyTimeoutWorkItem = nil

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }

    private static func makeWebsocketURL(
        temporaryToken: String?,
        keyterms: [String]
    ) throws -> URL {
        guard var websocketURLComponents = URLComponents(string: websocketBaseURLString) else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL is invalid."
            )
        }

        var queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "format_turns", value: "true"),
            URLQueryItem(name: "speech_model", value: "u3-rt-pro")
        ]

        let normalizedKeyterms = keyterms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalizedKeyterms.isEmpty,
           let keytermsData = try? JSONSerialization.data(withJSONObject: normalizedKeyterms),
           let keytermsJSONString = String(data: keytermsData, encoding: .utf8) {
            queryItems.append(URLQueryItem(name: "keyterms_prompt", value: keytermsJSONString))
        }

        if let temporaryToken {
            queryItems.append(URLQueryItem(name: "token", value: temporaryToken))
        }

        websocketURLComponents.queryItems = queryItems

        guard let websocketURL = websocketURLComponents.url else {
            throw AssemblyAIStreamingTranscriptionProviderError(
                message: "AssemblyAI websocket URL could not be created."
            )
        }

        return websocketURL
    }
}
