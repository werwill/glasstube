import Foundation

/// Opciones de arranque para capturas y pruebas que también lee la lógica (en la app de Mac viven en `Automation`):
/// `-GTAnonimo YES` cambia en pantalla el nombre, el correo y el avatar de la cuenta por unos de prueba, y
/// `-GTSinCorreo YES` oculta solo los correos.
public enum CaptureMode {
    public static var masksAccount: Bool { UserDefaults.standard.bool(forKey: "GTAnonimo") }
    public static var hidesEmails: Bool { UserDefaults.standard.bool(forKey: "GTSinCorreo") || masksAccount }
}
