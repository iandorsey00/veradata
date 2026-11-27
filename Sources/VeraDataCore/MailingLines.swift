import Foundation

struct MailingLines {
    let text: String
    let missingFields: [String]

    /// Expand only recognized address keys, once, against this record.
    static func render(_ template: String, fields: [String: JSONValue]) -> Self? {
        let placeholder = #/\{\{[ \t]*(recipient|name|line1|streetAddress|line2|unit|unitNumber|city|region|postalCode|country)[ \t]*\}\}/#
        guard template.firstMatch(of: placeholder) != nil else { return nil }
        var missingFields: [String] = []
        let text = template.components(separatedBy: "\n").compactMap { line -> String? in
            let matches = line.matches(of: placeholder)
            guard !matches.isEmpty else { return line }
            var result = ""
            var cursor = line.startIndex
            var foundValue = false
            var missingValue = false
            for match in matches {
                result += line[cursor..<match.range.lowerBound]
                let key = fieldKey(match.1)
                let value = component(key, in: fields)?.string ?? ""
                let isBlank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if isBlank {
                    missingValue = true
                    if !missingFields.contains(key) { missingFields.append(key) }
                    while result.last == " " || result.last == "\t" { result.removeLast() }
                } else {
                    foundValue = true
                    result += value
                }
                cursor = match.range.upperBound
            }
            guard foundValue else { return nil }
            result += line[cursor...]
            return missingValue
                ? result.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",，")))
                : result
        }.joined(separator: "\n")
        return Self(text: text, missingFields: missingFields)
    }

    private static func fieldKey(_ placeholder: Substring) -> String {
        switch placeholder {
        case "name": return "recipient"
        case "streetAddress": return "line1"
        case "unit", "unitNumber": return "line2"
        default: return String(placeholder)
        }
    }

    private static func component(_ key: String, in fields: [String: JSONValue]) -> JSONValue? {
        switch key {
        case "recipient": return fields[key] ?? fields["name"]
        case "line2": return fields[key] ?? fields["unit"] ?? fields["unitNumber"]
        default: return fields[key]
        }
    }
}
