import Foundation
import FonaCore

/// German and English UI texts. Every key needs both languages – the switch makes a missing one a compile error.
enum L {
    enum Key: CaseIterable {
        case favorites, allStations, recentlyPlayed, newsSwitch, newsNext, newsNow, newsBackTo, backNow, newsStillOn, toNews, interrupted, playing
        case searchPlaceholder, countries, worldwide, addStation, addTitle, streamLink, name, nameHint, addToFavorites
        case cancel, add, checking, linkOK, noFavorites, noResults, noDirectory
        case settings, newsSection, newsStation, scheduleLabel, scheduleHint, hourly, hourlyAndHalf, maxDuration, minutes
        case stationsSection, showCountries, addCountry, general, launchAtLogin, autoUpdate, language, languageSystem
        case support, selfTest, selfTestHint, runSelfTest, report, reportButton, showLog, likeFona, likeFonaHint, coffee
        case play, pause, settingsButton, favoriteAdd, favoriteRemove, rename, remove, quit, connecting, buffering, reconnecting
        case libraryReset, selfTestPassed, selfTestFailed, stationCount, sortedByPopularity, sortedByName, findSong, done
        case updates, version, checkNow, upToDate, updateCheckFailed, updateFailed, updateAvailable, install, skipUpdate, installManual, betas, betasHint
        case moveToApplications, manual, about, aboutCopyright, aboutLicense, aboutWarranty, sourceCode, license, showManual
        case on, off, newsOnAir, backTo, stationNotFavourite
        case close, hideFona, closeSettings, edit, undo, redo, cut, copy, paste, selectAll, volume, clearSearch
        case selfTestRunning, reportSent, reportSaved, reportFailed, reportTitle, reportDescription, reportContact, reportAttach, send
    }

    static var language: Messages.Language = .en

    static func t(_ k: Key) -> String {
        let (de, en) = pair(k)
        return language == .de ? de : en
    }

    static func pair(_ k: Key) -> (String, String) {
        switch k {
        case .favorites: return ("Favoriten", "Favourites")
        case .allStations: return ("Alle Sender", "All Stations")
        case .recentlyPlayed: return ("Zuletzt gehört", "Recently Played")
        case .newsSwitch: return ("Nachrichten-Umschaltung", "News Switch")
        case .newsNext: return ("Deutschlandfunk · nächste um %@", "Deutschlandfunk · next at %@")
        case .newsNow: return ("Läuft gerade", "On air now")
        case .newsBackTo: return ("Danach zurück zu %@", "Then back to %@")
        case .backNow: return ("Jetzt zurück", "Back Now")
        case .newsStillOn: return ("Nachrichten laufen", "News still on")
        case .toNews: return ("Zu den Nachrichten", "To the News")
        case .interrupted: return ("unterbrochen", "interrupted")
        case .playing: return ("läuft", "playing")
        case .searchPlaceholder: return ("Sender suchen", "Search stations")
        case .countries: return ("Länder", "Countries")
        case .worldwide: return ("Weltweit", "Worldwide")
        case .addStation: return ("Eigenen Stream-Link hinzufügen", "Add your own stream link")
        case .addTitle: return ("Sender hinzufügen", "Add Station")
        case .streamLink: return ("Stream-Link", "Stream Link")
        case .name: return ("Name", "Name")
        case .nameHint: return ("Vom Stream übernommen, du kannst ihn ändern.", "Taken from the stream – you can change it.")
        case .addToFavorites: return ("Zu Favoriten hinzufügen", "Add to Favourites")
        case .cancel: return ("Abbrechen", "Cancel")
        case .add: return ("Hinzufügen", "Add")
        case .checking: return ("Prüfe den Link …", "Checking the link …")
        case .linkOK: return ("Stream erreichbar · %@", "Stream reachable · %@")
        case .noFavorites: return ("Füge Sender über „Alle Sender“ hinzu.", "Add stations from “All Stations”.")
        case .noResults: return ("Keine Sender gefunden.", "No stations found.")
        case .noDirectory: return ("Keine Verbindung zum Senderverzeichnis.", "No connection to the station directory.")
        case .settings: return ("Einstellungen", "Settings")
        case .newsSection: return ("Nachrichten", "News")
        case .newsStation: return ("Nachrichtensender", "News station")
        case .scheduleLabel: return ("Zeitplan", "Schedule")
        case .scheduleHint: return ("Nachrichten werden nur zu diesen Zeiten erkannt.", "News is only detected at these times.")
        case .hourly: return ("Jede volle Stunde", "Every full hour")
        case .hourlyAndHalf: return ("Volle und halbe Stunde", "Full and half hour")
        case .maxDuration: return ("Höchstdauer, falls kein Ende erkannt wird", "Maximum length if no end is detected")
        case .minutes: return ("%d Min.", "%d min")
        case .stationsSection: return ("Senderliste", "Station List")
        case .showCountries: return ("Länder anzeigen", "Show countries")
        case .addCountry: return ("Land hinzufügen", "Add country")
        case .general: return ("Allgemein", "General")
        case .launchAtLogin: return ("Beim Anmelden starten", "Open at login")
        case .autoUpdate: return ("Automatisch nach Updates suchen", "Check for updates automatically")
        case .language: return ("Sprache", "Language")
        case .languageSystem: return ("Wie das System", "Same as system")
        case .support: return ("Support", "Support")
        case .selfTest: return ("Selbsttest", "Self-Test")
        case .selfTestHint: return ("Prüft alle Funktionen mit eigenen Testdaten.", "Checks every function with its own test data.")
        case .runSelfTest: return ("Selbsttest starten …", "Run Self-Test …")
        case .report: return ("Problem melden", "Report a problem")
        case .reportButton: return ("Melden …", "Report …")
        case .showLog: return ("Protokoll zeigen", "Show Log")
        case .likeFona: return ("Gefällt dir Fona?", "Like Fona?")
        case .likeFonaHint: return ("Wenn du Fona nutzt und magst, freue ich mich über einen Kaffee.", "If you use Fona and like it, I would be glad if you bought me a coffee.")
        case .coffee: return ("Buy me a coffee", "Buy me a coffee")
        case .play: return ("Abspielen", "Play")
        case .pause: return ("Pause", "Pause")
        case .settingsButton: return ("Einstellungen", "Settings")
        case .favoriteAdd: return ("Zu Favoriten", "Add to Favourites")
        case .favoriteRemove: return ("Aus Favoriten entfernen", "Remove from Favourites")
        case .rename: return ("Umbenennen …", "Rename …")
        case .remove: return ("Entfernen", "Remove")
        case .quit: return ("Fona beenden", "Quit Fona")
        case .connecting: return ("Verbinde …", "Connecting …")
        case .buffering: return ("Puffere …", "Buffering …")
        case .reconnecting: return ("Verbindung verloren – neuer Versuch %d von %d", "Connection lost – retry %d of %d")
        case .libraryReset: return ("Deine Senderliste war beschädigt und wurde zurückgesetzt. Die alte Datei liegt als library.broken.json im Ordner von Fona.", "Your station list was damaged and has been reset. The old file is kept as library.broken.json in Fona’s folder.")
        case .selfTestPassed: return ("Selbsttest bestanden: %d Prüfungen.", "Self-test passed: %d checks.")
        case .selfTestFailed: return ("Selbsttest: %d von %d Prüfungen fehlgeschlagen.", "Self-test: %d of %d checks failed.")
        case .stationCount: return ("%d Sender", "%d stations")
        case .sortedByPopularity: return ("sortiert nach Beliebtheit", "sorted by popularity")
        case .findSong: return ("Song bei Streamingdienst suchen", "Find song on a streaming service")
        case .sortedByName: return ("alle Sender von A bis Z", "all stations from A to Z")
        case .done: return ("Fertig", "Done")
        case .selfTestRunning: return ("Selbsttest läuft …", "Self-test running …")
        case .reportSent: return ("Bericht gesendet. Danke!", "Report sent. Thank you!")
        case .reportSaved: return ("Senden fehlgeschlagen – der Bericht liegt im Ordner „Reports“ von Fona.", "Sending failed – the report was saved in Fona’s “Reports” folder.")
        case .reportFailed: return ("Der Bericht konnte weder gesendet noch gespeichert werden.", "The report could neither be sent nor saved.")
        case .reportTitle: return ("Problem melden", "Report a Problem")
        case .reportDescription: return ("Was ist passiert?", "What happened?")
        case .reportContact: return ("E-Mail für Rückfragen (freiwillig)", "E-mail for questions (optional)")
        case .reportAttach: return ("Systeminfo und Protokoll anhängen (ohne Sendernamen und Links)", "Attach system info and log (without station names and links)")
        case .send: return ("Senden", "Send")
        case .close: return ("Schließen", "Close")
        case .hideFona: return ("Fona ausblenden", "Hide Fona")
        case .closeSettings: return ("Einstellungen schließen", "Close Settings")
        case .edit: return ("Bearbeiten", "Edit")
        case .undo: return ("Widerrufen", "Undo")
        case .redo: return ("Wiederholen", "Redo")
        case .cut: return ("Ausschneiden", "Cut")
        case .copy: return ("Kopieren", "Copy")
        case .paste: return ("Einsetzen", "Paste")
        case .selectAll: return ("Alles auswählen", "Select All")
        case .volume: return ("Lautstärke", "Volume")
        case .clearSearch: return ("Suche löschen", "Clear search")
        case .on: return ("Ein", "On")
        case .off: return ("Aus", "Off")
        case .newsOnAir: return ("Nachrichten von Deutschlandfunk", "News from Deutschlandfunk")
        case .backTo: return ("Zurück zu %@", "Back to %@")
        case .stationNotFavourite: return ("%@, kein Favorit", "%@, not a favourite")
        case .updates: return ("Updates", "Updates")
        case .version: return ("Version %@", "Version %@")
        case .checkNow: return ("Jetzt suchen", "Check Now")
        case .upToDate: return ("Fona ist aktuell.", "Fona is up to date.")
        case .updateCheckFailed: return ("Konnte nicht nach Updates suchen. Prüfe die Internetverbindung.", "Could not check for updates. Check the internet connection.")
        case .updateFailed: return ("Das Update konnte nicht geladen oder geprüft werden.", "The update could not be downloaded or verified.")
        case .updateAvailable: return ("Fona %@ ist verfügbar.", "Fona %@ is available.")
        case .install: return ("Installieren", "Install")
        case .skipUpdate: return ("Überspringen", "Skip")
        case .installManual: return ("Dieses Update muss von Hand installiert werden.", "This update has to be installed by hand.")
        case .betas: return ("Testversionen erhalten", "Get test versions")
        case .betasHint: return ("Vorabversionen zum Ausprobieren, können Fehler enthalten.", "Pre-releases for trying out, may contain bugs.")
        case .moveToApplications: return ("Bitte zieh Fona in den Programme-Ordner und starte es von dort – sonst kann es sich nicht aktualisieren.", "Please move Fona to the Applications folder and open it from there – otherwise it cannot update itself.")
        case .manual: return ("Handbuch", "Manual")
        case .showManual: return ("Handbuch öffnen", "Open Manual")
        case .about: return ("Über Fona", "About Fona")
        case .aboutCopyright: return ("© 2026 Moritz Poth", "© 2026 Moritz Poth")
        case .aboutLicense: return ("Fona ist freie Software: Du kannst sie unter der GNU General Public License, Version 3 oder neuer, weitergeben und verändern.", "Fona is free software: you can redistribute it and/or modify it under the GNU General Public License, version 3 or later.")
        case .aboutWarranty: return ("Fona wird OHNE JEDE GEWÄHRLEISTUNG bereitgestellt. Senderverzeichnis: radio-browser.info. Fona ist nicht mit Deutschlandfunk verbunden.", "Fona comes with ABSOLUTELY NO WARRANTY. Station directory: radio-browser.info. Fona is not affiliated with Deutschlandfunk.")
        case .sourceCode: return ("Quellcode", "Source Code")
        case .license: return ("Lizenz", "License")
        }
    }

    static func f(_ k: Key, _ args: CVarArg...) -> String { String(format: t(k), arguments: args) }

    /// Country name in the UI language – never the server's text.
    static func country(_ code: String) -> String {
        Locale(identifier: language.rawValue).localizedString(forRegionCode: code) ?? code
    }
}
