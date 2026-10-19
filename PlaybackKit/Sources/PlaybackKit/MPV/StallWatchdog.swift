import Foundation

/// Vigila que la reproducción avance cuando debería: mpv dice que reproduce (o que espera datos), la caché ya tiene
/// datos por delante y no hay pausa ni una llegada en curso, pero `time-pos` no se mueve. Es el síntoma de «video en
/// negro en 0:00» que vio la app una vez (fase 1) y que no se pudo repetir: si vuelve a pasar, el motor deja el estado en
/// la bitácora (ventana, VO, caché) y le da a mpv un empujón (un seek exacto en la misma posición, que rehace el primer
/// cuadro), a lo más `maxNudges` veces por carga.
struct StallWatchdog {
    /// Segundos sin avance antes de actuar.
    var threshold: TimeInterval = 6
    /// Datos mínimos por delante (s) para descartar que solo falte red.
    var minimumAhead: Double = 2
    var maxNudges = 2

    private(set) var nudges = 0
    private var lastPosition: Double?
    private var since: Date?

    /// Nueva carga (o búsqueda): se empieza a medir de cero.
    mutating func reset() {
        nudges = 0
        lastPosition = nil
        since = nil
    }

    /// Devuelve verdadero cuando hay que empujar. `expectsProgress`: no hay pausa del usuario ni de mpv, ni una llegada
    /// o carga en curso.
    mutating func check(position: Double?, expectsProgress: Bool, ahead: Double?, now: Date = Date()) -> Bool {
        guard expectsProgress, (ahead ?? 0) >= minimumAhead else {
            // Mientras no se espera avance, el reloj no corre.
            since = nil
            lastPosition = position
            return false
        }
        if let position, let last = lastPosition, abs(position - last) > 0.05 {
            lastPosition = position
            since = now
            return false
        }
        lastPosition = position ?? lastPosition
        guard let start = since else {
            since = now
            return false
        }
        guard now.timeIntervalSince(start) >= threshold, nudges < maxNudges else { return false }
        nudges += 1
        since = now
        return true
    }
}
