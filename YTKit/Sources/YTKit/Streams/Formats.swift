import Foundation

/// Respuesta de /youtubei/v1/player (solo los campos que usa la fase 0; `VideoInfo.java` en SmartTube).
public struct PlayerResponse: Decodable, Sendable {
    public struct PlayabilityStatus: Decodable, Sendable {
        public let status: String?
        public let reason: String?
    }

    public struct StreamingData: Decodable, Sendable {
        public let expiresInSeconds: String?
        public let formats: [RawFormat]?
        public let adaptiveFormats: [RawFormat]?
        public let hlsManifestUrl: String?
        public let dashManifestUrl: String?
        public let serverAbrStreamingUrl: String?
    }

    /// `playerConfig.mediaCommonConfig.mediaUstreamerRequestConfig.videoPlaybackUstreamerConfig` (configuración opaca de SABR).
    public struct PlayerConfig: Decodable, Sendable {
        public struct MediaCommonConfig: Decodable, Sendable {
            public struct MediaUstreamerRequestConfig: Decodable, Sendable {
                public let videoPlaybackUstreamerConfig: String?
            }
            public let mediaUstreamerRequestConfig: MediaUstreamerRequestConfig?
        }
        public let mediaCommonConfig: MediaCommonConfig?
    }

    public struct VideoDetails: Decodable, Sendable {
        public let videoId: String?
        public let title: String?
        public let author: String?
        public let lengthSeconds: String?
        public let isLive: Bool?
        public let isLiveContent: Bool?
    }

    public let playabilityStatus: PlayabilityStatus?
    public let streamingData: StreamingData?
    public let videoDetails: VideoDetails?
    public let playerConfig: PlayerConfig?

    public var videoPlaybackUstreamerConfig: String? {
        playerConfig?.mediaCommonConfig?.mediaUstreamerRequestConfig?.videoPlaybackUstreamerConfig
    }
}

public struct RawFormat: Decodable, Sendable {
    public struct ColorInfo: Decodable, Sendable {
        public let primaries: String?
        public let transferCharacteristics: String?
    }

    public struct AudioTrack: Decodable, Sendable {
        public let displayName: String?
        public let id: String?
        public let audioIsDefault: Bool?
    }

    public let itag: Int
    public let url: String?
    public let signatureCipher: String?
    public let cipher: String?
    public let mimeType: String
    public let bitrate: Int?
    public let averageBitrate: Int?
    public let width: Int?
    public let height: Int?
    public let fps: Int?
    public let qualityLabel: String?
    public let contentLength: String?
    public let audioQuality: String?
    public let audioSampleRate: String?
    public let audioChannels: Int?
    public let colorInfo: ColorInfo?
    public let isDrc: Bool?
    public let audioTrack: AudioTrack?
    public let xtags: String?
    /// Microsegundos desde la época; forma parte del `FormatId` de SABR (`last_modified`).
    public let lastModified: String?
    public let approxDurationMs: String?
}

public enum Codec: String, Sendable, CaseIterable {
    case vp9, av1, avc, opus, aac, eac3, ac3, other

    static func from(mimeType: String) -> Codec {
        let codecs = mimeType.firstMatch(#"codecs="([^"]+)""#)?.lowercased() ?? ""
        if codecs.hasPrefix("vp9") || codecs.hasPrefix("vp09") { return .vp9 }
        if codecs.hasPrefix("av01") { return .av1 }
        if codecs.hasPrefix("avc1") { return .avc }
        if codecs.hasPrefix("opus") { return .opus }
        if codecs.hasPrefix("mp4a") { return .aac }
        if codecs.hasPrefix("ec-3") { return .eac3 }
        if codecs.hasPrefix("ac-3") { return .ac3 }
        return .other
    }
}

/// Formato ya resuelto: firma aplicada, `n` transformado y, si hizo falta, `pot` añadido.
public struct StreamFormat: Sendable {
    public enum Kind: String, Sendable { case video, audio, muxed }

    public let itag: Int
    public let kind: Kind
    public let codec: Codec
    public let mimeType: String
    public let width: Int?
    public let height: Int?
    public let fps: Int?
    public let bitrate: Int
    public let contentLength: Int64?
    public let qualityLabel: String?
    public let isHDR: Bool
    public let isDRC: Bool
    public let audioTrack: String?
    public let isDefaultAudio: Bool
    public let audioTrackId: String?
    public let lastModified: UInt64?
    public let xtags: String?
    public let approxDurationMs: Int64?
    public let audioSampleRate: String?
    public let audioChannels: Int?
    public var url: String?
    /// La URL venía en `signatureCipher` (firma cifrada).
    public var hadCipher: Bool
    public var signatureSolved: Bool
    /// La URL traía parámetro `n` y se transformó (n de salida distinto al de entrada).
    public var nPresent: Bool
    public var nSolved: Bool

    public var container: String { mimeType.firstMatch(#"^\w+/(\w+)"#) ?? "?" }

    public var label: String {
        switch kind {
        case .audio:
            let rate = audioSampleRate.map { "\(Int($0).map { $0 / 1000 } ?? 0)kHz" } ?? ""
            return "\(bitrate / 1000)k \(rate)\(isDRC ? " DRC" : "")\(audioTrack.map { " [\($0)]" } ?? "")"
        case .video, .muxed:
            return "\(width ?? 0)x\(height ?? 0)\(fps.map { "@\($0)" } ?? "")\(isHDR ? " HDR" : "")"
        }
    }

    init(raw: RawFormat, kind: Kind) {
        itag = raw.itag
        self.kind = kind
        codec = Codec.from(mimeType: raw.mimeType)
        mimeType = raw.mimeType
        width = raw.width
        height = raw.height
        fps = raw.fps
        bitrate = raw.bitrate ?? raw.averageBitrate ?? 0
        contentLength = raw.contentLength.flatMap { Int64($0) }
        qualityLabel = raw.qualityLabel
        let transfer = raw.colorInfo?.transferCharacteristics ?? ""
        isHDR = transfer.contains("SMPTEST2084") || transfer.contains("ARIB_STD_B67") || (raw.qualityLabel?.contains("HDR") ?? false)
        isDRC = raw.isDrc ?? false
        audioTrack = raw.audioTrack?.displayName
        isDefaultAudio = raw.audioTrack?.audioIsDefault ?? true
        audioTrackId = raw.audioTrack?.id
        lastModified = raw.lastModified.flatMap { UInt64($0) }
        xtags = raw.xtags
        approxDurationMs = raw.approxDurationMs.flatMap { Int64($0) }
        audioSampleRate = raw.audioSampleRate
        audioChannels = raw.audioChannels
        url = raw.url
        hadCipher = raw.url == nil && (raw.signatureCipher ?? raw.cipher) != nil
        signatureSolved = false
        nPresent = false
        nSolved = false
    }
}

extension PlayerResponse {
    public var isPlayable: Bool { playabilityStatus?.status == "OK" }

    /// Formatos adaptativos (video y audio separados) más los combinados, sin resolver todavía.
    public func rawFormats() -> [(RawFormat, StreamFormat.Kind)] {
        var result: [(RawFormat, StreamFormat.Kind)] = []
        for raw in streamingData?.adaptiveFormats ?? [] {
            result.append((raw, raw.mimeType.hasPrefix("audio/") ? .audio : .video))
        }
        for raw in streamingData?.formats ?? [] {
            result.append((raw, .muxed))
        }
        return result
    }
}

/// Selección de pistas para reproducir (versión simple del puntaje de SmartTube: códec VP9 > AVC > AV1, luego fps y bitrate).
public enum TrackSelector {
    /// `requireURL: false` para SABR, donde los formatos no traen URL propia.
    public static func bestVideo(_ formats: [StreamFormat], maxHeight: Int? = nil, codecOrder: [Codec] = [.vp9, .avc, .av1],
                                 allowHDR: Bool = false, requireURL: Bool = true) -> StreamFormat? {
        let candidates = formats.filter { format in
            format.kind == .video && (format.url != nil || !requireURL) && (allowHDR || !format.isHDR)
                && (maxHeight.map { (format.height ?? 0) <= $0 } ?? true) && codecOrder.contains(format.codec)
        }
        return candidates.max { a, b in
            if (a.height ?? 0) != (b.height ?? 0) { return (a.height ?? 0) < (b.height ?? 0) }
            let ra = codecOrder.firstIndex(of: a.codec) ?? 99, rb = codecOrder.firstIndex(of: b.codec) ?? 99
            if ra != rb { return ra > rb }
            if (a.fps ?? 0) != (b.fps ?? 0) { return (a.fps ?? 0) < (b.fps ?? 0) }
            return a.bitrate < b.bitrate
        }
    }

    public static func bestAudio(_ formats: [StreamFormat], codecOrder: [Codec] = [.opus, .aac], requireURL: Bool = true) -> StreamFormat? {
        let candidates = formats.filter { $0.kind == .audio && ($0.url != nil || !requireURL) && codecOrder.contains($0.codec) }
        return candidates.max { a, b in
            if a.isDefaultAudio != b.isDefaultAudio { return !a.isDefaultAudio }
            if a.isDRC != b.isDRC { return a.isDRC }
            let ra = codecOrder.firstIndex(of: a.codec) ?? 99, rb = codecOrder.firstIndex(of: b.codec) ?? 99
            if a.bitrate / 16000 != b.bitrate / 16000 { return a.bitrate < b.bitrate }
            return ra > rb
        }
    }
}
