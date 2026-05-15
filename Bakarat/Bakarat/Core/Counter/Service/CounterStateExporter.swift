//
//  CounterStateExporter.swift
//  Bakarat
//
//  Export et parse du texte représentant l'état d'un compteur (joueurs +
//  soldes + prix + dealer). L'objectif : un format lisible à l'œil que
//  l'utilisateur peut partager dans un message, recopier à la main au pire,
//  et coller dans la sheet de création pour reprendre l'état d'une partie.
//

import Foundation

// MARK: - Modèle décodé

struct CounterStateImport {
    var name: String?
    var linePrice: Double
    var currency: String
    var dealerName: String?
    /// (name, score)
    var activePlayers: [(name: String, score: Double)]
    var inactivePlayers: [(name: String, score: Double)]
}

// MARK: - Service

enum CounterStateExporter {

    // MARK: Export

    static func export(counter: Counter) -> String {
        let active = counter.activePlayersOrdered
        let inactive = counter.inactivePlayersOrdered

        var lines: [String] = []
        lines.append("Bakarat 3-boards — \(counter.name)")
        lines.append("Prix : \(formatPrice(counter.linePrice)) \(counter.currency)/ligne")
        if let dealer = active.first(where: { $0.seat == counter.dealerIdx }) {
            lines.append("Dealer : \(dealer.name)")
        }
        lines.append("")

        lines.append("Joueurs actifs :")
        if active.isEmpty {
            lines.append("- (aucun)")
        } else {
            for p in active {
                lines.append("- \(p.name) : \(formatSigned(p.score)) \(counter.currency)")
            }
        }

        if !inactive.isEmpty {
            lines.append("")
            lines.append("Joueurs inactifs :")
            for p in inactive {
                lines.append("- \(p.name) : \(formatSigned(p.score)) \(counter.currency)")
            }
        }

        if counter.manches.count > 0 {
            lines.append("")
            let n = counter.manches.count
            lines.append("Manche\(n > 1 ? "s" : "") validée\(n > 1 ? "s" : "") : \(n)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: Parse

    /// Parse un texte arbitraire — retourne nil si on n'a pas trouvé au moins
    /// 2 joueurs identifiables. Tolérant aux variantes (avec/sans bullets,
    /// avec/sans devise en suffixe, ":" ou "=" comme séparateur, …).
    static func parse(_ raw: String) -> CounterStateImport? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{2212}", with: "-")  // unicode minus
        let lines = normalized.components(separatedBy: "\n")

        var name: String? = nil
        var linePrice: Double? = nil
        var currency: String = "€"
        var dealerName: String? = nil
        var actives: [(String, Double)] = []
        var inactives: [(String, Double)] = []

        enum Section { case active, inactive }
        var section: Section = .active

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            // Header "Bakarat 3-boards — Nom"
            let lower = line.lowercased()
            if lower.hasPrefix("bakarat") || lower.hasPrefix("baccarat") {
                if let dash = line.range(of: " — ") ?? line.range(of: " - ") {
                    let extracted = String(line[dash.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    if !extracted.isEmpty { name = extracted }
                }
                continue
            }

            // "Prix : 1 €/ligne"
            if lower.hasPrefix("prix") {
                let after = line.dropFirst("prix".count)
                let trimmed = after.drop(while: { ":= ".contains($0) || $0 == " " })
                let (value, sym) = extractNumberAndCurrency(String(trimmed))
                if let value { linePrice = value }
                if let sym { currency = sym }
                continue
            }

            // "Dealer : Alice"
            if lower.hasPrefix("dealer") || lower.hasPrefix("donne") || lower.hasPrefix("donneur") {
                let parts = line.split(separator: ":", maxSplits: 1).map { String($0) }
                if parts.count == 2 {
                    dealerName = parts[1].trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            // Section markers
            if lower.contains("inactif") {
                section = .inactive
                continue
            }
            if lower.contains("actif") || lower.contains("joueurs :") || lower.contains("joueurs:") {
                section = .active
                continue
            }
            if lower.contains("manche") && lower.contains("valid") {
                // Just a comment, skip
                continue
            }

            // Player line: "- {Name} : {±score} [{currency}]"
            if let player = parsePlayerLine(line, currencyHint: currency) {
                if player.currency != nil { currency = player.currency! }
                switch section {
                case .active:   actives.append((player.name, player.score))
                case .inactive: inactives.append((player.name, player.score))
                }
            }
        }

        guard actives.count + inactives.count >= 2 else { return nil }

        return CounterStateImport(
            name: name,
            linePrice: linePrice ?? 1.0,
            currency: currency,
            dealerName: dealerName,
            activePlayers: actives,
            inactivePlayers: inactives
        )
    }

    private static func parsePlayerLine(_ rawLine: String, currencyHint: String) -> (name: String, score: Double, currency: String?)? {
        // Strip leading bullet ("-", "•", "*", "·") + whitespace
        var line = rawLine
        for bullet in ["- ", "• ", "* ", "·  ", "·"] {
            if line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count))
                break
            }
        }
        line = line.trimmingCharacters(in: .whitespaces)

        // Split on ":" or "="
        let separators = [":", "="]
        var separatorIdx: String.Index? = nil
        for sep in separators {
            if let r = line.range(of: sep) {
                separatorIdx = r.lowerBound
                break
            }
        }
        guard let sepIdx = separatorIdx else { return nil }

        let namePart = String(line[..<sepIdx]).trimmingCharacters(in: .whitespaces)
        let amountPart = String(line[line.index(after: sepIdx)...]).trimmingCharacters(in: .whitespaces)
        guard !namePart.isEmpty else { return nil }

        // Strip "(inactif)" / "(actif)" suffixes from name
        let cleanName = stripParens(namePart)

        let (value, currency) = extractNumberAndCurrency(amountPart)
        guard let value else { return nil }
        return (cleanName, value, currency)
    }

    private static func stripParens(_ s: String) -> String {
        var out = s
        while let openIdx = out.firstIndex(of: "("),
              let closeIdx = out.firstIndex(of: ")"),
              openIdx < closeIdx {
            out.removeSubrange(openIdx...closeIdx)
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Extrait le premier nombre signé (avec décimales `.` ou `,`) du texte,
    /// + le symbole monétaire s'il est présent à la suite. Renvoie (nil, nil)
    /// si pas de nombre.
    private static func extractNumberAndCurrency(_ raw: String) -> (Double?, String?) {
        let pattern = #"([+-]?\d+(?:[.,]\d+)?)\s*([€$£]|CHF)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, nil) }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range) else { return (nil, nil) }
        let numRange = Range(match.range(at: 1), in: raw)
        let numStr = numRange.map { String(raw[$0]) }?.replacingOccurrences(of: ",", with: ".")
        let value = numStr.flatMap { Double($0) }
        var currency: String? = nil
        if match.numberOfRanges >= 3, let cRange = Range(match.range(at: 2), in: raw) {
            let s = String(raw[cRange])
            if !s.isEmpty { currency = s }
        }
        return (value, currency)
    }

    // MARK: - Formatting

    private static func formatPrice(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func formatSigned(_ value: Double) -> String {
        if abs(value) < 0.001 { return "0" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        let abs = formatter.string(from: NSNumber(value: abs(value))) ?? "\(abs(value))"
        return value > 0 ? "+\(abs)" : "−\(abs)"
    }
}
