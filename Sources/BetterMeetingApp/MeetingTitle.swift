import Foundation
import NaturalLanguage

enum MeetingTitle {
    /// Suggests a title off the caller's executor. Cancelling the caller stops tagging early.
    static func suggestInBackground(from text: String) async -> String? {
        let tagging = Task.detached(priority: .utility) { suggest(from: text) }
        return await withTaskCancellationHandler {
            await tagging.value
        } onCancel: {
            tagging.cancel()
        }
    }

    /// Returns nil once the current task is cancelled, without tagging the rest of the text.
    static func suggest(from text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass, .lemma])
        tagger.string = text
        guard let language = tagger.dominantLanguage else { return nil }
        guard NLTagger.availableTagSchemes(for: .word, language: language).contains(.nameTypeOrLexicalClass)
        else { return suggestUntagged(from: text) }

        var words: [(text: String, lemma: String, tag: NLTag?, range: Range<String.Index>)] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameTypeOrLexicalClass,
            options: [.omitWhitespace, .omitPunctuation, .omitOther, .joinNames]
        ) { tag, range in
            let word = String(text[range])
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? word
            words.append((word, (lemma.isEmpty ? word : lemma).lowercased(), tag, range))
            return !Task.isCancelled
        }
        guard !Task.isCancelled else { return nil }

        let nameKeys = Set(words.filter { $0.tag == .personalName || $0.tag == .organizationName }
            .map { $0.text.lowercased() })
        var productKeys: Set<String> = []
        // ponytail: infer products from recurring capitalized nouns until NaturalLanguage offers a product tag.
        let products = Dictionary(grouping: words.filter {
            $0.tag == .noun && !ignored.contains($0.lemma)
                && $0.text.contains(where: \.isUppercase) && $0.text != $0.text.uppercased()
        }, by: { $0.text.lowercased() })
        for (key, mentions) in products where mentions.count >= 2 {
            guard !Task.isCancelled else { return nil }
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
        return title(names: Array(names.values), topics: Array(topics.values))
    }

    /// For languages NaturalLanguage cannot tag, such as Ukrainian. The subject is a capitalized word mentioned at
    /// least twice, once inside a sentence so that sentence-initial capitals do not count; the topic is a repeated
    /// word or adjacent pair of words of four or more letters that is neither a name nor in `untaggedIgnored`.
    private static func suggestUntagged(from text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.tokenType])
        tagger.string = text
        var words: [(text: String, key: String, range: Range<String.Index>)] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .tokenType,
            options: [.omitWhitespace, .omitPunctuation, .omitOther]
        ) { _, range in
            words.append((String(text[range]), stem(String(text[range])), range))
            return !Task.isCancelled
        }
        guard !Task.isCancelled else { return nil }

        var names: [String: (text: String, count: Int, index: Int)] = [:]
        var nameKeys: Set<String> = []
        var subjectKeys: Set<String> = []
        for (index, word) in words.enumerated() where word.text.contains(where: \.isUppercase) {
            guard !Task.isCancelled else { return nil }
            let sentence = tagger.tokenRange(for: word.range, unit: .sentence)
            let insideSentence = text[sentence.lowerBound..<word.range.lowerBound].contains(where: \.isLetter)
            if insideSentence { nameKeys.insert(word.key) }
            guard word.text.first?.isUppercase == true, word.text != word.text.uppercased(),
                  !untaggedIgnored.contains(word.key) else { continue }
            names[word.key, default: (word.text, 0, index)].count += 1
            if insideSentence { subjectKeys.insert(word.key) }
        }

        func isTopicWord(_ word: (text: String, key: String, range: Range<String.Index>)) -> Bool {
            word.text.allSatisfy { $0.isLetter || "'’ʼ".contains($0) } && word.text.filter(\.isLetter).count >= 4
                && !nameKeys.contains(word.key) && !untaggedIgnored.contains(word.key)
        }
        var topics: [String: (text: String, count: Int, length: Int, index: Int)] = [:]
        for (index, word) in words.enumerated() where isTopicWord(word) {
            topics[word.key, default: (word.text, 0, 1, index)].count += 1
            guard index > 0, isTopicWord(words[index - 1]) else { continue }
            let previous = words[index - 1]
            let gap = text[previous.range.upperBound..<word.range.lowerBound]
            if !gap.isEmpty, gap.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let phrase = "\(previous.key) \(word.key)"
                topics[phrase, default: ("\(previous.text) \(word.text)", 0, 2, index - 1)].count += 1
            }
        }
        return title(
            names: names.filter { subjectKeys.contains($0.key) && $0.value.count >= 2 }.map(\.value),
            topics: Array(topics.values)
        )
    }

    /// Joins the most mentioned name, earliest on ties, with the repeated topic scoring highest on count × words.
    private static func title(
        names: [(text: String, count: Int, index: Int)],
        topics: [(text: String, count: Int, length: Int, index: Int)]
    ) -> String? {
        let name = names.min {
            $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index
        }
        let topic = topics.filter { $0.count >= 2 }.min {
            let leftScore = $0.count * $0.length
            let rightScore = $1.count * $1.length
            if leftScore != rightScore { return leftScore > rightScore }
            if $0.length != $1.length { return $0.length > $1.length }
            return $0.index < $1.index
        }
        guard let name, let topic else { return nil }
        return MeetingArtifacts.sanitizedTitle("\(name.text) — \(topic.text.capitalized)")
    }

    /// A crude stem so case forms meet ("система", "систему", "системою" → "систем"): lowercase, one apostrophe,
    /// and up to two trailing vowels, soft signs or "й" dropped from words of six letters or more. A heuristic, not
    /// morphology: consonant endings ("системам") stay apart, and two unrelated words can occasionally meet.
    private static func stem(_ word: String) -> String {
        var stem = String(word.lowercased().map { "’ʼ".contains($0) ? "'" : $0 })
        guard stem.count >= 6 else { return stem }
        for _ in 0..<2 where "аеєиіїоуюяьйыэёaeiouy".contains(stem.last!) { stem.removeLast() }
        return stem
    }

    private static let ignored: Set<String> = [
        "thing", "stuff", "meeting", "call", "topic", "time", "today", "tomorrow", "yesterday",
        "day", "week", "month", "year", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Untagged text has no word classes to skip, so `ignored` plus Ukrainian, then Russian, meeting and time words,
    /// fillers and function words. Compared by stem; forms the stem does not join are listed separately.
    private static let untaggedIgnored = Set((Array(ignored) + """
        зустріч дзвінок дзвінка мітинг тема теми тему темі часу сьогодні завтра вчора учора день днів
        тиждень тижня тижні тижнів місяць місяців року роки років наступного наступний наступному минулого
        минулий минулому понеділок понеділка вівторок вівторка середа четвер четверга п'ятниця субота неділя
        січень січня лютий лютого березень березня квітень квітня травень травня червень червня липень липня
        серпень серпня вересень вересня жовтень жовтня листопад грудень грудня
        будь ласка наприклад тобто також зараз потім просто давайте давай можна треба можемо потрібно якщо
        коли тоді тому чому дуже буде було були була будемо може можу мене мені тебе тобі його йому вона вони
        цього цьому цієї який якої якого якому яких тільки більше щось типу значить звичайно звісно можливо
        добре окей дякую думаю знаю дивись слухай взагалі коротше напевно мабуть через після перед навіть
        інший інша інше інші такий така таке такі саме немає нема робити зробити всіх всім усіх
        встреча созвон звонок звонка темы время времени сегодня вчера дней неделя месяц месяцев года году
        следующий следующего прошлый прошлого понедельник вторник среда среду четверг пятница суббота
        воскресенье январь февраль март марта апрель июнь июня июль июля август сентябрь октябрь ноябрь декабрь
        пожалуйста например также тоже сейчас потом можно нужно надо можем если когда тогда потому почему
        очень будет будем могу меня тебя него этот этого этой этом этих который которых только больше значит
        конечно хорошо ладно спасибо смотри слушай вообще короче наверное даже другой такой такая такое такие
        есть нету делать сделать
        """.split(whereSeparator: \.isWhitespace).map(String.init)).map(stem))
}
