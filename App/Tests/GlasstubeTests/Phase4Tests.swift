import AppKit
import CoreImage
import Foundation
import PlaybackKit
import Testing
import YTKit
@testable import Glasstube

/// Fase 4: lo que la app arma para el control remoto y Spotlight, sin red.
@MainActor
@Suite struct Phase4Tests {
    /// El QR de la hoja se puede leer y lleva lo mismo que el de la app de TV.
    @Test func pairingQRCodeIsReadable() throws {
        let code = LoungePairingCode(digits: "123456789012")
        let image = try #require(QRCodeView.image(for: code.pairURL.absoluteString))
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        // Con margen blanco, como en la hoja (el detector necesita la zona en blanco alrededor).
        let scaled = CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let padded = scaled.transformed(by: CGAffineTransform(translationX: 80, y: 80))
            .composited(over: CIImage(color: .white).cropped(to: scaled.extent.insetBy(dx: -80, dy: -80).offsetBy(dx: 80, dy: 80)))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let messages = detector.features(in: padded).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(messages == ["https://youtube.com/pair/123456789012?qr=1"])
    }

    /// Estados del motor → lo que entiende el teléfono (cargando = 3, como SmartTube).
    @Test func playbackStatesForThePhone() {
        #expect(RemoteControl.loungeState(.playing) == .playing)
        #expect(RemoteControl.loungeState(.paused) == .paused)
        #expect(RemoteControl.loungeState(.ended) == .ended)
        #expect(RemoteControl.loungeState(.buffering) == .buffering)
        #expect(RemoteControl.loungeState(.loading) == .buffering)
        #expect(RemoteControl.loungeState(nil) == .buffering)
    }

    /// Lo que guarda Spotlight y lo que se abre al elegir el resultado.
    @Test func spotlightIdentifiersOpenTheRightThing() {
        #expect(SpotlightIndex.identifier(video: "aqz-KE-bpKQ") == "video:aqz-KE-bpKQ")
        #expect(SpotlightIndex.link(for: "video:aqz-KE-bpKQ") == .video(id: "aqz-KE-bpKQ"))
        #expect(SpotlightIndex.link(for: SpotlightIndex.identifier(channel: "UCSMOQeBJ2RAnuFungnQOxLg")) == .channel("UCSMOQeBJ2RAnuFungnQOxLg"))
        #expect(SpotlightIndex.link(for: "otro:x") == nil)
        #expect(SpotlightIndex.link(for: "video") == nil)
    }

    /// El nombre por omisión en el teléfono.
    @Test func defaultScreenName() {
        #expect(RemoteControl.defaultName.hasPrefix("Glasstube en "))
    }
}
