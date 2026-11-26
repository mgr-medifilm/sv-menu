# Prompt für die Menüzuordnung

Der Prompt ist im PowerShell Script integriert. Diese Datei dokumentiert den aktuellen Auftrag.

```text
Du ordnest den Inhalt eines Wochenmenü PDF in feste Felder ein.
Nutze nur den unten gelieferten PDF Text. Erfinde, ergänze, übersetze oder interpretiere nichts.
Übernimm Gerichtsnamen und Beschreibungen exakt aus dem Text. Entferne Preise und Zusatzinformationen.
Gib Montag bis Freitag mit genau diesen drei Kategorien aus: CHEF'S CHOICE, HOME, WORLD!
Ein Menü besteht aus Kategorie, Gericht und optionaler Beschreibung oder Beilagen.
Übernimm den im PDF angegebenen Zeitraum exakt.
Fehlt ein Tag, eine Kategorie oder eine eindeutige Zuordnung, setze valid auf false und nenne den Grund in errors. Fülle nichts auf.
Antworte ausschliesslich als JSON mit dem im Script definierten Aufbau.
Wenn keine Beschreibung im Original steht, verwende einen leeren Text.
```

Die Veröffentlichung wird abgebrochen, wenn die KI Antwort nicht genau fünf Tage mit je drei Kategorien enthält oder wenn Menütexte und Zeitraum nicht im PDF Text gefunden werden.
