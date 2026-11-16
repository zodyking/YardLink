import Foundation

/// Container and chassis markings as they are painted on the equipment.
///
/// The server is the authority on every number. This is the same reading of
/// ISO 6346 the web app does in the browser, so a driver sees a wrong digit
/// while typing and not only after sending.
enum Marking {
    /// Uppercase letters and digits only.
    static func normalize(_ input: String) -> String {
        String(input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// Four letters, then up to `digits` digits; everything else is dropped.
    private static func mask(_ input: String, digits limit: Int) -> String {
        var letters = ""
        var digits = ""
        for character in input.uppercased() where character.isASCII {
            if letters.count < 4 {
                if character.isLetter { letters.append(character) }
                continue
            }
            if digits.count < limit, character.isNumber { digits.append(character) }
        }
        return letters + digits
    }

    /// Owner code, category letter, serial and the boxed check digit.
    static func maskContainer(_ input: String) -> String { mask(input, digits: 7) }

    /// Four letters and six digits; a chassis has no check digit.
    static func maskChassis(_ input: String) -> String { mask(input, digits: 6) }

    /// `MSCU452189-4`. A partial value keeps the same grouping.
    static func formatContainer(_ input: String?) -> String {
        let compact = maskContainer(input ?? "")
        guard compact.count > 10 else { return compact }
        return "\(compact.prefix(10))-\(compact.suffix(1))"
    }

    static func isCompleteChassis(_ input: String) -> Bool { maskChassis(input).count == 10 }

    /// ISO 6346 letter values: A is 10, counting up and skipping multiples of 11.
    private static let letterValues: [Character: Int] = {
        var values: [Character: Int] = [:]
        var value = 10
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            while value % 11 == 0 { value += 1 }
            if let unicode = UnicodeScalar(scalar) { values[Character(unicode)] = value }
            value += 1
        }
        return values
    }()

    /// The check digit for the first ten characters, or nil when they are not
    /// four letters and six digits.
    static func checkDigit(for prefix: String) -> Int? {
        let characters = Array(normalize(prefix).prefix(10))
        guard characters.count == 10 else { return nil }
        var sum = 0
        var weight = 1
        for (index, character) in characters.enumerated() {
            let candidate = index < 4 ? letterValues[character] : character.wholeNumberValue
            guard let value = candidate else { return nil }
            sum += value * weight
            weight *= 2
        }
        return (sum % 11) % 10
    }

    struct ContainerCheck {
        let normalized: String
        /// Four letters and seven digits.
        let structureValid: Bool
        /// Structure is right and the boxed digit matches.
        let valid: Bool
        let expectedCheckDigit: Int?
        let problem: String?
        let note: String?
    }

    static func checkContainer(_ input: String) -> ContainerCheck {
        let normalized = normalize(input)
        let characters = Array(normalized)
        let structureValid = characters.count == 11
            && characters.prefix(4).allSatisfy(\.isLetter)
            && characters.suffix(7).allSatisfy(\.isNumber)

        guard structureValid else {
            let problem: String
            if normalized.isEmpty {
                problem = "Container number is required."
            } else if normalized.count != 11 {
                problem = "Container numbers are 11 characters; this has \(normalized.count)."
            } else {
                problem = "Expected four letters followed by seven digits, like MSCU4521894."
            }
            return ContainerCheck(normalized: normalized, structureValid: false, valid: false, expectedCheckDigit: nil, problem: problem, note: nil)
        }

        let expected = checkDigit(for: normalized)
        let given = characters[10].wholeNumberValue
        let valid = expected != nil && expected == given

        var note: String?
        switch characters[3] {
        case "U": note = nil
        case "Z": note = "Category Z identifies a trailer or chassis, not a freight container."
        case "J": note = "Category J identifies detachable container equipment, not a freight container."
        default: note = "Equipment category \(characters[3]) is outside ISO 6346 (expected U, J or Z)."
        }

        return ContainerCheck(
            normalized: normalized,
            structureValid: true,
            valid: valid,
            expectedCheckDigit: expected,
            problem: valid ? nil : "The check digit does not match. The boxed digit should be \(expected.map(String.init) ?? "different").",
            note: note
        )
    }
}

/// Choices a driver makes when a container is new to the company. The
/// values are the server's; the labels are what is painted on the box.
enum EquipmentChoices {
    static let lines: [(value: String, label: String)] = [
        ("TROPICAL", "Tropical"),
        ("ZIM", "ZIM"),
        ("CMA", "CMA"),
        ("KING_OCEAN", "King Ocean"),
    ]

    static let sizes: [(value: String, label: String)] = [
        ("DRY_20", "20ft"),
        ("DRY_40", "40ft"),
    ]
}
