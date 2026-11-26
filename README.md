# SV Wochenmenü für den Infoscreen

Dieses Repository lädt wöchentlich das aktuelle Mittagsmenü für Galexis AG, dailys, Niederbipp, verarbeitet den Text mit Gemini und veröffentlicht eine einseitige PDF Datei sowie ein JPG auf GitHub Pages.

## Was der Ablauf macht

1. GitHub Actions startet am Montag um 03:20 UTC oder manuell über `workflow_dispatch`.
2. Das PowerShell Script öffnet die Menüseite mit Edge im Headless Modus und findet den aktuellen PDF Download Link.
3. Das PDF wird heruntergeladen und mit Poppler geprüft und ausgelesen.
4. Gemini ordnet die Speisen Montag bis Freitag und den Kategorien CHEF'S CHOICE, HOME und WORLD! zu.
5. Das Script prüft Tage, Kategorien, Menünamen, Beschreibungen, Zeitraum und Preise.
6. Bei erfolgreicher Prüfung werden eine 16:9 PDF Seite, ein JPG und eine kleine Webseite erzeugt.
7. GitHub Pages veröffentlicht die Dateien.

Wenn ein Schritt fehlschlägt, wird der GitHub Pages Schritt nicht ausgeführt. Die letzte veröffentlichte Ausgabe bleibt online.

## Kostenloser Betrieb

Für ein öffentliches Repository sind GitHub Actions Standard Runner und GitHub Pages laut den aktuellen GitHub Tarifen kostenlos verfügbar. Gemini wird über die kostenlose API Stufe verwendet. Aktiviere für dieses Projekt keine kostenpflichtige API Abrechnung. Diese Stufe hat Kontingente und kann sich ändern. Google kann Inhalte aus der kostenlosen API Stufe zur Verbesserung seiner Produkte verwenden. Das Menü ist öffentlich, trotzdem sollte der API Schlüssel nie veröffentlicht werden.

## Repository auf GitHub anlegen

1. Melde dich bei GitHub an und erstelle ein neues Repository mit dem Namen `sv-wochenmenu`.
2. Setze die Sichtbarkeit auf **Public**.
3. Lade alle Dateien aus diesem Ordner in das Repository hoch. Die Datei `.github/workflows/weekly-menu.yml` muss samt Ordnerstruktur enthalten sein.
4. Erstelle in Google AI Studio einen API Schlüssel für die Gemini API.
5. Öffne im Repository `Settings`, dann `Secrets and variables`, danach `Actions`. Erstelle ein Repository Secret mit dem Namen `GEMINI_API_KEY` und füge dort den API Schlüssel ein.
6. Öffne `Settings`, dann `Pages`. Wähle bei **Build and deployment** die Option **GitHub Actions**.
7. Öffne `Actions`, wähle **Weekly menu** und starte **Run workflow** auf dem Branch `main`.
8. Warte, bis die Schritte **Download, process, and render menu** und **Publish to GitHub Pages** erfolgreich sind.
9. Die öffentliche Adresse wird im Repository unter `Settings`, `Pages` angezeigt. Sie hat die Form `https://DEIN-KONTO.github.io/sv-wochenmenu/`.

## Öffentliche Ausgabedateien

Die Webseite zeigt das aktuelle Menü. Das Bild ist unter `wochenmenu.jpg` verfügbar. Der PDF Dateiname enthält Kalenderwoche und Jahr, zum Beispiel `Wochenmenu_KW_48_2026_Infoscreen.pdf`.

## Manuell erneut ausführen

Öffne `Actions`, wähle **Weekly menu**, klicke **Run workflow** und bestätige mit dem Branch `main`.

## Fehlersuche

Öffne bei einem fehlgeschlagenen Lauf `Actions`, wähle den Lauf und lies den Schritt mit dem roten Fehlerstatus.

* `Das GitHub Secret GEMINI_API_KEY fehlt`: Secret gemäss Anleitung hinzufügen.
* `SV lieferte KW ... erwartet ...`: Der Download ist nicht für die laufende ISO Kalenderwoche. Es erfolgt absichtlich keine Veröffentlichung.
* `KI konnte den Plan nicht eindeutig lesen`: PDF Text oder Kategorien prüfen. Die bestehende Ausgabe bleibt bestehen.
* `Text ... nicht wörtlich im PDF Text auffindbar`: Die KI hat wahrscheinlich umformuliert oder der PDF Text wurde anders extrahiert. Ausgabe wird blockiert.
* API Fehler: API Schlüssel, Modellname und freies Kontingent prüfen.

## Sicherheit und Datenschutz

Das Repository und die veröffentlichte Webseite sind öffentlich. Der Gemini Schlüssel muss als GitHub Secret gespeichert werden. Er darf nicht im Script, in einer Datei oder in einem Protokoll stehen. Der Workflow schreibt den signierten PDF Link nicht in seine Ausgabe.

Die Menüinformationen werden an die Gemini API gesendet. Bei der kostenlosen API Stufe kann Google die Inhalte zur Verbesserung der Produkte verwenden. Der Workflow sendet nur Text aus dem öffentlichen Menü PDF.

## Technische Hinweise

Der Lauf verwendet den von GitHub gehosteten Windows Server 2022 Runner. Edge ist auf diesem Runner vorinstalliert. Poppler wird bei Bedarf aus dem offiziellen Release Archiv geladen und vor Verwendung per SHA256 geprüft.

Das Script erwartet den PDF Dateinamen im SV Muster mit Kalenderwoche und Datum. Die Menüseite oder das PDF Format kann sich ändern. Dann wird der Lauf fehlschlagen und keine neue Ausgabe veröffentlichen.
