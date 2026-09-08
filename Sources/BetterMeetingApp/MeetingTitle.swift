import Foundation
import NaturalLanguage

enum MeetingTitle {
    static func suggest(from text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.string = text
        guard let language = tagger.dominantLanguage,
              NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameTypeOrLexicalClass)
        else { return nil }

        var words: [(text: String, lemma: String, tag: NLTag?, range: Range<String.Index>)] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        ) { tag, range in
            let word = String(text[range])
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? word
            words.append((word, (lemma.isEmpty ? word : lemma).lowercased(), tag, range))
            return true
        }

        let ignored: Set<String> = [
            "thing", "stuff", "meeting", "call", "topic", "time", "today", "tomorrow", "yesterday",
            "day", "week", "month", "year", "monday", "tuesday", "wednesday", "thursday", "friday",
            "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
            "august", "september", "october", "november", "december",
        ]
        let nameKeys = Set(words.filter { $0.tag == .personalName || $0.tag == .organizationName }
            .map { $0.text.lowercased() })
        var productKeys: Set<String> = []
        // ponytail: infer products from recurring capitalized nouns until NaturalLanguage offers a product tag.
        let products = Dictionary(grouping: words.filter {
            $0.tag == .noun && !ignored.contains($0.lemma)
                && $0.text.contains(where: \.isUppercase) && $0.text != $0.text.uppercased()
        }, by: { $0.text.lowercased() })
        for (key, mentions) in products where mentions.count >= 2 {
            if mentions.contains(where: { word in
                let sentence = tagger.tokenRange(for: word.range, unit: .sentence)
                return word.text.dropFirst().contains(where: \.isUppercase)
                    || text[sentence.lowerBound..<word.range.lowerBound].contains(where: \.isLetter)
            }) {
                productKeys.insert(key)
            }
        }

        let subjectKeys = nameKeys.isEmpty ? productKeys : nameKeys
        let excludedNames = nameKeys.union(productKeys)
        var names: [String: (text: String, count: Int, index: Int)] = [:]
        var topics: [String: (text: String, count: Int, length: Int, index: Int)] = [:]
        for (index, word) in words.enumerated() {
            let key = word.text.lowercased()
            if subjectKeys.contains(key) {
                names[key, default: (word.text, 0, index)].count += 1
                continue
            }
            guard word.tag == .noun, !ignored.contains(word.lemma), !excludedNames.contains(key) else { continue }
            topics[word.lemma, default: (word.text, 0, 1, index)].count += 1
            guard index > 0 else { continue }
            let previous = words[index - 1]
            let gap = text[previous.range.upperBound..<word.range.lowerBound]
            if (previous.tag == .noun || previous.tag == .adjective),
               !excludedNames.contains(previous.text.lowercased()), !ignored.contains(previous.lemma),
               !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let phrase = "\(previous.lemma) \(word.lemma)"
                topics[phrase, default: ("\(previous.text) \(word.text)", 0, 2, index - 1)].count += 1
            }
        }

        let name = names.values.min {
            $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index
        }
        let topic = topics.values.filter { $0.count >= 2 }.min {
            let leftScore = $0.count * $0.length
            let rightScore = $1.count * $1.length
            if leftScore != rightScore { return leftScore > rightScore }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.index < $1.index
        }
        guard let name, let topic else { return nil }
        return MeetingArtifacts.sanitizedTitle("\(name.text) — \(topic.text.capitalized)")
    }
}
