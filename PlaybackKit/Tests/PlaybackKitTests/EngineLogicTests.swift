import Foundation
import Testing
@testable import PlaybackKit

/// `#expect` no admite llamadas `mutating`: el vigilante va en una caja.
final class Box {
    var value = StallWatchdog()
    func check(position: Double?, expectsProgress: Bool, ahead: Double?, now: Date) -> Bool {
        value.check(position: position, expectsProgress: expectsProgress, ahead: ahead, now: now)
    }
}

@Suite struct StallWatchdogTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func nudgesOnlyAfterTheThresholdWithDataAhead() {
        let watchdog = Box()
        #expect(!watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start))
        #expect(!watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(5)))
        #expect(watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(6.5)))
        #expect(watchdog.value.nudges == 1)
        // Después de un empujón, otra vez el umbral completo.
        #expect(!watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(10)))
        #expect(watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(13)))
        // Y no más de `maxNudges`.
        #expect(!watchdog.check(position: 0, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(30)))
    }

    @Test func progressPauseOrMissingDataResetTheClock() {
        let watchdog = Box()
        _ = watchdog.check(position: 10, expectsProgress: true, ahead: 10, now: start)
        // Avanza: no hay atasco.
        #expect(!watchdog.check(position: 12, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(7)))
        #expect(!watchdog.check(position: 12, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(12)))
        // En pausa no corre el reloj.
        #expect(!watchdog.check(position: 12, expectsProgress: false, ahead: 10, now: start.addingTimeInterval(20)))
        #expect(!watchdog.check(position: 12, expectsProgress: true, ahead: 10, now: start.addingTimeInterval(21)))
        // Sin datos por delante es la red, no un atasco.
        #expect(!watchdog.check(position: 12, expectsProgress: true, ahead: 0.5, now: start.addingTimeInterval(40)))
        #expect(watchdog.value.nudges == 0)
    }

    @Test func noTimeAtAllAlsoCounts() {
        let watchdog = Box()
        #expect(!watchdog.check(position: nil, expectsProgress: true, ahead: 8, now: start))
        #expect(watchdog.check(position: nil, expectsProgress: true, ahead: 8, now: start.addingTimeInterval(6)))
        watchdog.value.reset()
        #expect(watchdog.value.nudges == 0)
    }
}

@Suite struct MPVHelpersTests {
    @Test func tracksFromTrackList() {
        let node = MPVNode.array([
            .map(["type": .string("video"), "id": .int(1), "codec": .string("vp9"), "demux-w": .int(1920), "demux-h": .int(1080),
                  "demux-fps": .double(60), "selected": .flag(true)]),
            .map(["type": .string("audio"), "id": .int(1), "lang": .string("es"), "selected": .flag(true)]),
            .map(["type": .string("sub"), "id": .int(2), "title": .string("Español"), "external": .flag(true)]),
            .map(["type": .string("otro"), "id": .int(9)]),
        ])
        let tracks = MPVEngine.tracks(from: node)
        #expect(tracks.map(\.id) == ["mpv:video:1", "mpv:audio:1", "mpv:sub:2"])
        #expect(tracks[0].title == "1080p vp9" && tracks[0].fps == 60 && tracks[0].isSelected)
        #expect(tracks[1].title == "es" && tracks[1].language == "es")
        #expect(tracks[2].kind == .subtitle && tracks[2].isExternal)
    }

    @Test func screenshotRawToImage() {
        var bytes = Data(count: 4 * 2 * 2)
        bytes[0] = 255
        let node = MPVNode.map(["w": .int(2), "h": .int(2), "stride": .int(8), "format": .string("bgr0"), "data": .bytes(bytes)])
        let image = MPVMetalView.image(from: node)
        #expect(image?.width == 2 && image?.height == 2)
        #expect(MPVMetalView.image(from: .map(["w": .int(0), "h": .int(0)])) == nil)
    }

    @Test func timeGateIgnoresTheOldFileUntilLoaded() {
        let gate = TimeGate()
        gate.fileLoaded()
        gate.position = 42
        gate.beginLoad()
        #expect(!gate.acceptsTime && gate.position == nil)
        gate.fileLoaded()
        #expect(gate.acceptsTime)
        #expect(gate.shouldPublishTime())
        #expect(!gate.shouldPublishTime())
    }
}
