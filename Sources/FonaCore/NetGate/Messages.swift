import Foundation

/// Plain-language texts for every `Rejection` (PLAN §5). Never contains foreign text from a server.
public enum Messages {
    public enum Language: String, Sendable { case de, en }

    public static func text(_ r: Rejection, _ lang: Language) -> String {
        let (de, en) = pair(r)
        return lang == .de ? de : en
    }

    static func pair(_ r: Rejection) -> (String, String) {
        switch r {
        case .badURL: return ("Das ist kein gültiger Link.", "This is not a valid link.")
        case .scheme("http"): return ("Für diese Verbindung ist nur eine verschlüsselte Adresse (https://) erlaubt.", "Only an encrypted address (https://) is allowed for this connection.")
        case .scheme: return ("Nur Links mit http:// oder https:// sind erlaubt.", "Only links starting with http:// or https:// are allowed.")
        case .credentialsInURL: return ("Links mit Benutzername oder Passwort sind nicht erlaubt.", "Links containing a user name or password are not allowed.")
        case .urlTooLong: return ("Dieser Link ist zu lang.", "This link is too long.")
        case .hostName: return ("Diese Adresse ist nicht erlaubt.", "This address is not allowed.")
        case .hostNotAllowed: return ("Dieser Server ist für diese Aufgabe nicht erlaubt.", "This server is not allowed for this task.")
        case .noAddress: return ("Der Server wurde nicht gefunden.", "The server could not be found.")
        case .privateAddress: return ("Sender im Heimnetz oder auf diesem Mac sind aus Sicherheitsgründen gesperrt.", "Stations on your home network or on this Mac are blocked for security reasons.")
        case .tooManyRedirects: return ("Der Link leitet zu oft weiter.", "The link redirects too many times.")
        case .redirectLoop: return ("Der Link leitet im Kreis weiter.", "The link redirects in a loop.")
        case .downgrade: return ("Der Server wollte auf eine unverschlüsselte Verbindung wechseln.", "The server tried to switch to an unencrypted connection.")
        case .headerTooLong, .badStatusLine, .badChunk: return ("Der Server antwortet nicht wie ein Radiosender.", "The server does not answer like a radio station.")
        case .headerTimeout, .connectTimeout: return ("Der Server antwortet nicht.", "The server does not respond.")
        case .httpStatus(let c): return ("Der Server meldet einen Fehler (\(c)).", "The server reports an error (\(c)).")
        case .contentEncoding: return ("Der Server schickt gepackte Daten, die Fona aus Sicherheitsgründen nicht annimmt.", "The server sends compressed data, which Fona does not accept for security reasons.")
        case .blockedContentType: return ("Dieser Link liefert keinen Ton, sondern zum Beispiel eine Webseite oder eine Datei.", "This link does not deliver sound but, for example, a web page or a file.")
        case .bodyTooLarge: return ("Der Server schickt mehr Daten als erlaubt.", "The server sends more data than allowed.")
        case .notAudio: return ("Dieser Link liefert keinen Ton in einem unterstützten Format (MP3, AAC, HLS).", "This link does not deliver sound in a supported format (MP3, AAC, HLS).")
        case .stalled: return ("Der Sender liefert keine Daten mehr.", "The station stopped sending data.")
        case .tooSlow: return ("Die Verbindung zum Sender ist zu langsam.", "The connection to the station is too slow.")
        case .tls: return ("Die sichere Verbindung zum Server ist fehlgeschlagen (Zertifikat ungültig).", "The secure connection to the server failed (invalid certificate).")
        case .network: return ("Keine Verbindung zum Internet.", "No connection to the internet.")
        }
    }
}
