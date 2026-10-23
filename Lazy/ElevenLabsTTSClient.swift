//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Text-to-speech client for ElevenLabs. Supports single-shot playback
//  (speakText) and a sentence queue used by the streaming reply path:
//  sentences play in order, and the next sentence's synthesis overlaps the
//  current sentence's playback so speech stays gapless.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    private let proxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?

    // MARK: - Sentence Queue

    /// Sentences waiting to be spoken, in order.
    private var pendingSentences: [String] = []
    /// True while the drain loop is consuming `pendingSentences`.
    private var isDrainingSentenceQueue = false
    /// Bumped by stopPlayback() so an in-flight drain loop exits instead of
    /// speaking sentences that were queued for a previous interaction.
    private var sentenceQueueGeneration = 0
    /// In-flight synthesis for the next queue item, overlapping current playback.
    private var prefetchedSentenceTask: Task<Data, Error>?

    /// Fired once when the queue hits a non-transient synthesis failure
    /// (HTTP 4xx quota/auth, 5xx after retry, the simulate seam) — the owner
    /// switches this reply to the system voice. Transient network errors are
    /// NOT reported; they keep the old skip-and-continue behavior.
    var onQueueFailure: ((Error) -> Void)?

    init(proxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Single-Shot Playback

    /// Sends `text` to ElevenLabs TTS and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    /// Supersedes any queued sentences.
    func speakText(_ text: String) async throws {
        stopPlayback()

        let data = try await fetchAudioDataWithRetry(for: text)
        try Task.checkCancellation()

        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.play()
        LazyLatency.markFirstTTSPaudio()
        print("🔊 ElevenLabs TTS: playing \(data.count / 1024)KB audio")
    }

    /// One quick retry for transient synthesis failures (dropped
    /// connection, 5xx). Quota/auth 4xx never retry — they won't heal.
    private func fetchAudioDataWithRetry(for text: String) async throws -> Data {
        do {
            return try await fetchAudioData(for: text)
        } catch {
            if Task.isCancelled { throw error }
            let nsError = error as NSError
            let isTransient = nsError.domain == NSURLErrorDomain
                || (nsError.domain == "ElevenLabsTTS" && nsError.code >= 500)
            guard isTransient else { throw error }
            print("↻ ElevenLabs TTS: transient failure — retrying once in 2s: \(error)")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            try Task.checkCancellation()
            return try await fetchAudioData(for: text)
        }
    }

    // MARK: - Sentence Queue

    /// Queues a sentence for in-order playback, starting the drain loop if it
    /// isn't already running. Sentence N+1's audio is synthesized while
    /// sentence N plays, so consecutive sentences have no synthesis gap.
    func enqueueSentence(_ sentence: String) {
        let trimmedSentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSentence.isEmpty else { return }
        pendingSentences.append(trimmedSentence)
        startDrainingSentenceQueueIfNeeded()
    }

    private func startDrainingSentenceQueueIfNeeded() {
        guard !isDrainingSentenceQueue else { return }
        isDrainingSentenceQueue = true
        let generation = sentenceQueueGeneration

        Task { [weak self] in
            await self?.drainSentenceQueue(generation: generation)
        }
    }

    private func drainSentenceQueue(generation: Int) async {
        while generation == sentenceQueueGeneration, !pendingSentences.isEmpty {
            let sentence = pendingSentences.removeFirst()

            // Start this sentence's synthesis NOW — it overlaps the previous
            // sentence's playback instead of waiting behind it.
            let fetchTask = Task<Data, Error> { [weak self] in
                guard let self else {
                    throw NSError(domain: "ElevenLabsTTS", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "TTS client deallocated"])
                }
                return try await self.fetchAudioDataWithRetry(for: sentence)
            }
            prefetchedSentenceTask = fetchTask

            // Wait for any current playback to finish before starting.
            while audioPlayer?.isPlaying == true {
                guard generation == sentenceQueueGeneration else {
                    fetchTask.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            guard generation == sentenceQueueGeneration else {
                fetchTask.cancel()
                return
            }

            do {
                let data = try await fetchTask.value
                guard generation == sentenceQueueGeneration else { return }
                guard !data.isEmpty, let player = try? AVAudioPlayer(data: data) else { continue }
                audioPlayer = player
                player.play()
                LazyLatency.markFirstTTSPaudio()
                print("🔊 ElevenLabs TTS: playing queued sentence (\(data.count / 1024)KB)")
            } catch {
                if error is CancellationError { return }
                let nsError = error as NSError
                if nsError.domain != NSURLErrorDomain {
                    // Non-transient (quota/auth/HTTP/seam): report it and drop
                    // the queue — the owner speaks the rest via system voice
                    // instead of letting the reply fall silent.
                    print("⚠️ ElevenLabs TTS: queued sentence failed permanently: \(error)")
                    onQueueFailure?(error)
                    pendingSentences.removeAll()
                    prefetchedSentenceTask = nil
                    isDrainingSentenceQueue = false
                    return
                }
                // Transient network failure — skip the sentence and keep
                // going; one failed synthesis shouldn't silence the rest.
                print("⚠️ ElevenLabs TTS: queued sentence failed, skipping: \(error)")
            }
        }

        if generation == sentenceQueueGeneration {
            isDrainingSentenceQueue = false
            prefetchedSentenceTask = nil
        }
    }

    /// Whether TTS audio is currently playing or queued-but-not-yet-spoken.
    var isPlaying: Bool {
        if audioPlayer?.isPlaying == true { return true }
        return isDrainingSentenceQueue
    }

    /// Stops any in-progress playback and drops queued sentences immediately.
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil

        sentenceQueueGeneration += 1
        pendingSentences.removeAll()
        prefetchedSentenceTask?.cancel()
        prefetchedSentenceTask = nil
        isDrainingSentenceQueue = false
    }

    // MARK: - Synthesis

    private func fetchAudioData(for text: String) async throws -> Data {
        // Test seam: forces every synthesis call to fail so the system-voice
        // real-outcome fallback can be drilled on demand.
        if UserDefaults.standard.bool(forKey: "clickySimulateTTSFailure") {
            throw NSError(domain: "ElevenLabsTTS", code: -999,
                          userInfo: [NSLocalizedDescriptionKey: "simulated TTS failure (clickySimulateTTSFailure)"])
        }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        // M7.1 — delivery shaping follows the active persona (the proxy
        // owns the voice itself; personality rides on stability/similarity).
        // Lazy's values are byte-identical to the pre-M7.1 constants.
        let persona = LazyPersona.persona(
            id: UserDefaults.standard.string(forKey: CompanionManager.activePersonaDefaultsKey) ?? LazyPersona.defaultID
        )
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": persona.elevenLabsStability,
                "similarity_boost": persona.elevenLabsSimilarity
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        return data
    }
}
