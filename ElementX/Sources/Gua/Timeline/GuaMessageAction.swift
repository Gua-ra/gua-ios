//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

import CryptoKit
import Foundation
import LRUCache
import SwiftSoup

/// A URL button that bots and integrations attach to a message under `global.gua.actions`.
/// Its URL is always linked from the formatted body too, so clients without buttons lose nothing.
nonisolated struct GuaMessageAction: Hashable, Sendable {
    let label: String
    /// Exactly as sent, which is what the body's hrefs and the other clients compare against.
    let rawURL: String
    let url: URL
    
    /// A label that reads as a different link gets the same phishing confirmation as a tapped link.
    var urlToOpen: URL {
        guard PhishingDetector.isPhishingAttempt(displayString: label, internalURL: url) else {
            return url
        }
        
        var components = URLComponents()
        components.scheme = URL.confirmationScheme
        components.host = ""
        components.queryItems = ConfirmURLParameters(internalURL: url, displayString: label).urlQueryItems
        return components.url ?? url
    }
    
    /// Removes this action's link text from the end of a rendered body, with the whitespace before it.
    /// Adjacent links to the same URL render as one run, so only the end that reads as the label goes; a run that does not, such as a pill, stays.
    func removingTrailingLink(from attributedString: AttributedString) -> AttributedString? {
        let characters = attributedString.characters
        let links = attributedString.runs[\.link].compactMap { link, range in link.map { (url: $0, range: range) } }
        guard let last = links.last, isTarget(of: last.url),
              characters[last.range.upperBound...].allSatisfy(\.isGuaWhiteSpace),
              var start = labelStart(in: characters, linkRange: last.range) else {
            return nil
        }
        
        while start > characters.startIndex {
            let previous = characters.index(before: start)
            guard characters[previous].isGuaWhiteSpace else { break }
            start = previous
        }
        
        var result = attributedString
        result.removeSubrange(start..<result.endIndex)
        return result
    }
    
    private func isTarget(of link: URL) -> Bool {
        link.absoluteString == url.absoluteString || link.confirmationParameters?.internalURL.absoluteString == url.absoluteString
    }
    
    /// Where the label starts at the end of the link's run, reading each run of White_Space in either as one space,
    /// because rendering can turn a CR or a `<br>` inside the link into a different line break or a space.
    private func labelStart(in characters: AttributedString.CharacterView, linkRange: Range<AttributedString.Index>) -> AttributedString.Index? {
        let space: Unicode.Scalar = " "
        let reversedLabel = Array(label.unicodeScalars.split(whereSeparator: \.isGuaWhiteSpace).joined(separator: [space]).reversed())
        var matched = 0
        var isAfterWhiteSpace = false
        var index = linkRange.upperBound
        while index > linkRange.lowerBound {
            index = characters.index(before: index)
            let character = characters[index]
            if character.isGuaWhiteSpace {
                // White_Space after the label's last character is trimmed, as the label is.
                isAfterWhiteSpace = matched > 0
                continue
            }
            
            let scalars = (isAfterWhiteSpace ? [space] : []) + character.unicodeScalars.reversed()
            isAfterWhiteSpace = false
            for scalar in scalars {
                guard matched < reversedLabel.count, reversedLabel[matched] == scalar else {
                    return nil
                }
                matched += 1
            }
            if matched == reversedLabel.count {
                return index
            }
        }
        return nil
    }
}

/// Reads and validates `global.gua.actions` as the shared spec describes. Anything invalid is dropped silently.
nonisolated enum GuaMessageActionParser {
    struct Result: Equatable, Sendable {
        var actions: [GuaMessageAction] = []
        /// The kept action whose link ends the formatted body. The button replaces that link on screen.
        var fallback: GuaMessageAction?
    }
    
    /// The parts of an event's content that the rules read, each nil when missing or of another JSON type.
    /// The fields left out are never decoded, so however deep they nest they cost no recursion here.
    struct Content: Decodable {
        var message: Message
        var isReplacement: Bool
        var newContent: Message?
        
        private enum CodingKeys: String, CodingKey {
            case relation = "m.relates_to", newContent = "m.new_content"
        }
        
        private enum RelationCodingKeys: String, CodingKey {
            case type = "rel_type"
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            message = try Message(from: decoder)
            let relation = try? container.nestedContainer(keyedBy: RelationCodingKeys.self, forKey: .relation)
            isReplacement = (try? relation?.decode(String.self, forKey: .type)) == "m.replace"
            newContent = try? container.decode(Message.self, forKey: .newContent)
        }
    }
    
    struct Message: Decodable {
        var messageType: String?
        var format: String?
        var formattedBody: String?
        var entries: [Entry]?
        
        private enum CodingKeys: String, CodingKey {
            case messageType = "msgtype", format, formattedBody = "formatted_body", entries = "global.gua.actions"
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            messageType = try? container.decode(String.self, forKey: .messageType)
            format = try? container.decode(String.self, forKey: .format)
            formattedBody = try? container.decode(String.self, forKey: .formattedBody)
            entries = try? container.decode([Entry].self, forKey: .entries)
        }
    }
    
    struct Entry: Decodable {
        var type: String?
        var label: String?
        var url: String?
        
        private enum CodingKeys: CodingKey {
            case type, label, url
        }
        
        /// Never throws, so an element of any JSON type is dropped on its own rather than with the whole array.
        init(from decoder: any Decoder) {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            type = try? container?.decode(String.self, forKey: .type)
            label = try? container?.decode(String.self, forKey: .label)
            url = try? container?.decode(String.self, forKey: .url)
        }
    }
    
    private struct Event: Decodable {
        var content: Content?
        
        private enum CodingKeys: CodingKey {
            case content
        }
        
        init(from decoder: any Decoder) throws {
            content = try? decoder.container(keyedBy: CodingKeys.self).decode(Content.self, forKey: .content)
        }
    }
    
    /// Rule 1's elements other than `<br>`, each in the only spelling it allows.
    private enum MarkupElement: String {
        case a, b, blockquote, code, del, div, em, h1, h2, h3, h4, h5, h6, i, li, ol, p, s, span, strong, sub, sup, u, ul
        
        var isHeading: Bool {
            [.h1, .h2, .h3, .h4, .h5, .h6].contains(self)
        }
        
        var isList: Bool {
            self == .ul || self == .ol
        }
        
        var isAllowedInParagraph: Bool {
            !isHeading && ![.blockquote, .div, .li, .ol, .p, .ul].contains(self)
        }
    }
    
    private enum MarkupTag {
        case start(MarkupElement)
        case end(MarkupElement)
        case lineBreak
    }
    
    static let contentKey = "global.gua.actions"
    
    private static let maxActions = 3
    /// In Unicode scalar values.
    private static let maxFormattedBodyLength = 4096
    private static let maxStartTags = 200
    private static let maxOpenElements = 20
    private static let maxOpenElementsWithOneName = 3
    private static let lineBreakTags = ["<br>", "<br/>", "<br />"].map { Array($0.utf8) }
    private static let hrefPrefix = Array("href=".utf8)
    /// What may follow an `&`, besides a numeric reference.
    private static let allowedNamedReferences = ["amp;", "lt;", "gt;", "quot;", "apos;", "nbsp;"].map { Array($0.utf8) }
    private static let allowedControls: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", "\r"]
    private static let labelLengths = 1...40
    private static let maxURLLength = 2048
    private static let maxPort = 65535
    private static let urlCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?@!$&'()*+,;=".utf8)
    /// Every timeline diff rebuilds every item, so this holds as many entries as the attributed string cache; a digest key keeps no event JSON alive.
    private static let cache = LRUCache<SHA256.Digest, Result>(countLimit: 1000)
    
    static func parse(eventJSON: String) -> Result {
        guard eventJSON.contains(contentKey) else {
            return Result()
        }
        
        let key = SHA256.hash(data: Data(eventJSON.utf8))
        if let cached = cache.value(forKey: key) {
            return cached
        }
        
        // JSONSerialization would drop a leading U+FEFF from every string and key; JSONDecoder keeps them as JSON.parse does.
        let content = (try? JSONDecoder().decode(Event.self, from: Data(eventJSON.utf8)))?.content
        let result = content.map(parse(content:)) ?? Result()
        cache.setValue(result, forKey: key)
        return result
    }
    
    static func parse(content: Content) -> Result {
        guard let message = displayedContent(of: content),
              let messageType = message.messageType, ["m.text", "m.notice"].contains(messageType),
              message.format == "org.matrix.custom.html",
              let formattedBody = message.formattedBody,
              passesRawChecks(formattedBody),
              let entries = message.entries else {
            return Result()
        }
        
        let candidates = entries.prefix(maxActions).compactMap(candidate(from:))
        // Every parser builds rule 1's markup as written, so this document parse gives the tree of the spec's fragment parse.
        guard !candidates.isEmpty, let body = try? SwiftSoup.parse("<body>" + preprocessed(formattedBody)).body() else {
            return Result()
        }
        
        let hrefs = (try? body.select("a"))?.compactMap { try? $0.attr("href") } ?? []
        var actions = [GuaMessageAction]()
        for candidate in candidates where hrefs.contains(where: { $0.isIdentical(to: candidate.rawURL) }) {
            if !actions.contains(where: { $0.rawURL.isIdentical(to: candidate.rawURL) }) {
                actions.append(candidate)
            }
        }
        
        guard !actions.isEmpty else {
            return Result()
        }
        
        let fallback = trailingLink(in: body).flatMap { link -> GuaMessageAction? in
            guard let href = try? link.attr("href") else {
                return nil
            }
            let text = textContent(of: link).trimmingGuaWhiteSpace()
            return actions.first { $0.rawURL.isIdentical(to: href) && $0.label.isIdentical(to: text) }
        }
        
        return Result(actions: actions, fallback: fallback)
    }
    
    /// An edit is displayed from `m.new_content`, so its actions come from there too, and a relation repeated inside it is ignored.
    private static func displayedContent(of content: Content) -> Message? {
        content.isReplacement ? content.newContent : content.message
    }
    
    /// Rule 1 on the raw string, before any parse: one pass reads each tag in its exact form and tracks the open elements,
    /// so the tree every HTML parser builds is the one the tags describe.
    private static func passesRawChecks(_ html: String) -> Bool {
        guard html.unicodeScalars.count <= maxFormattedBodyLength,
              !html.unicodeScalars.contains(where: { ($0.isGuaControl && !allowedControls.contains($0)) || $0.isGuaNoncharacter }) else {
            return false
        }
        
        let bytes = Array(html.utf8)
        var openElements = [MarkupElement]()
        var startTags = 0
        var index = 0
        while index < bytes.count {
            // Some renderers drop everything directly in a list but its items.
            let isInList = openElements.last?.isList == true
            switch bytes[index] {
            case UInt8(ascii: "&"):
                guard !isInList, let end = referenceEnd(in: bytes, at: index) else {
                    return false
                }
                index = end
            case UInt8(ascii: "<"):
                guard let tag = readTag(in: bytes, at: index) else {
                    return false
                }
                switch tag.kind {
                case .lineBreak where !isInList:
                    startTags += 1
                case .start(let element) where canOpen(element, inside: openElements):
                    startTags += 1
                    openElements.append(element)
                case .end(let element) where openElements.last == element:
                    openElements.removeLast()
                default:
                    return false
                }
                guard startTags <= maxStartTags else {
                    return false
                }
                index = tag.end
            case let byte:
                guard !isInList || isASCIIWhitespace(byte) else {
                    return false
                }
                index += 1
            }
        }
        return openElements.isEmpty
    }
    
    /// Reads the tag that the `<` at `start` begins, written exactly in one of rule 1's forms, up to just past its `>`.
    private static func readTag(in bytes: [UInt8], at start: Int) -> (kind: MarkupTag, end: Int)? {
        if let lineBreak = lineBreakTags.first(where: { bytes[start...].starts(with: $0) }) {
            return (.lineBreak, start + lineBreak.count)
        }
        
        let isEndTag = bytes.dropFirst(start + 1).first == UInt8(ascii: "/")
        let nameStart = start + (isEndTag ? 2 : 1)
        // Only a to z and 0 to 9 are read as the name, so upper case or a look-alike such as U+212A never matches.
        let nameEnd = bytes[nameStart...].firstIndex { !isLowercaseLetter($0) && !isDigit($0) } ?? bytes.endIndex
        guard let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .ascii), let element = MarkupElement(rawValue: name) else {
            return nil
        }
        
        var end = nameEnd
        if !isEndTag, element == .a, end < bytes.count, isASCIIWhitespace(bytes[end]) {
            guard let hrefEnd = hrefEnd(in: bytes, at: end) else {
                return nil
            }
            end = hrefEnd
        }
        guard end < bytes.count, bytes[end] == UInt8(ascii: ">") else {
            return nil
        }
        return (isEndTag ? .end(element) : .start(element), end + 1)
    }
    
    /// Reads the TAB, LF, FF, CR or space characters at `start`, then `href=` and a quoted value, up to just past the closing quote.
    /// The value has no `<`, `>` or quote of its own kind, and its references follow the same rule as the text's.
    private static func hrefEnd(in bytes: [UInt8], at start: Int) -> Int? {
        let nameStart = bytes[start...].firstIndex { !isASCIIWhitespace($0) } ?? bytes.endIndex
        let quoteIndex = nameStart + hrefPrefix.count
        guard bytes[nameStart...].starts(with: hrefPrefix), quoteIndex < bytes.count,
              bytes[quoteIndex] == UInt8(ascii: "\"") || bytes[quoteIndex] == UInt8(ascii: "'") else {
            return nil
        }
        
        var index = quoteIndex + 1
        while index < bytes.count, bytes[index] != bytes[quoteIndex] {
            switch bytes[index] {
            case UInt8(ascii: "<"), UInt8(ascii: ">"):
                return nil
            case UInt8(ascii: "&"):
                guard let end = referenceEnd(in: bytes, at: index) else {
                    return nil
                }
                index = end
            default:
                index += 1
            }
        }
        return index < bytes.count ? index + 1 : nil
    }
    
    /// Reads the reference that the `&` at `start` begins, up to just past its `;`: one of the six named ones,
    /// or a numeric one naming a Unicode scalar value that is not a control character or a noncharacter.
    private static func referenceEnd(in bytes: [UInt8], at start: Int) -> Int? {
        let rest = bytes[(start + 1)...]
        if let name = allowedNamedReferences.first(where: { rest.starts(with: $0) }) {
            return rest.startIndex + name.count
        }
        guard rest.first == UInt8(ascii: "#") else {
            return nil
        }
        
        let isHex = rest.dropFirst().first == UInt8(ascii: "x") || rest.dropFirst().first == UInt8(ascii: "X")
        let digits = rest.dropFirst(isHex ? 2 : 1).prefix(while: isHex ? isHexDigit : isDigit)
        guard (isHex ? 1...6 : 1...7).contains(digits.count),
              bytes.dropFirst(digits.endIndex).first == UInt8(ascii: ";"),
              let digitString = String(bytes: digits, encoding: .ascii),
              let value = UInt32(digitString, radix: isHex ? 16 : 10),
              let scalar = Unicode.Scalar(value), !scalar.isGuaControl, !scalar.isGuaNoncharacter else {
            return nil
        }
        return digits.endIndex + 1
    }
    
    /// Rule 1's nesting, which leaves out every place where HTML parsers close, move or rebuild elements on their own.
    private static func canOpen(_ element: MarkupElement, inside openElements: [MarkupElement]) -> Bool {
        guard openElements.count < maxOpenElements,
              openElements.count(where: { $0 == element }) < maxOpenElementsWithOneName,
              element != .a || !openElements.contains(.a),
              !element.isHeading || !openElements.contains(where: \.isHeading),
              element.isAllowedInParagraph || !openElements.contains(.p),
              // An `li` opens directly inside a list, and nothing else does.
              (element == .li) == (openElements.last?.isList == true) else {
            return false
        }
        return true
    }
    
    /// Rules 3 to 5. Rule 6 needs the parsed body, so it is checked afterwards.
    private static func candidate(from entry: Entry) -> GuaMessageAction? {
        guard entry.type == "open_url",
              let label = entry.label?.trimmingGuaWhiteSpace(),
              labelLengths.contains(label.unicodeScalars.count),
              let rawURL = entry.url,
              isAllowedURL(rawURL),
              let url = URL(string: rawURL) else {
            return nil
        }
        return GuaMessageAction(label: label, rawURL: rawURL, url: url)
    }
    
    /// Spec rule 5, checked on the raw string because URL parsers disagree on what they accept.
    private static func isAllowedURL(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        let scheme = Array("https://".utf8)
        guard bytes.count <= maxURLLength,
              bytes.starts(with: scheme),
              var index = hostEnd(in: bytes, from: scheme.count) else {
            return false
        }
        
        if index < bytes.count, bytes[index] == UInt8(ascii: ":") {
            let digits = bytes[(index + 1)...].prefix(while: isDigit)
            guard digits.first != UInt8(ascii: "0"),
                  (1...5).contains(digits.count),
                  digits.reduce(0, { $0 * 10 + Int($1 - UInt8(ascii: "0")) }) <= maxPort else {
                return false
            }
            index += 1 + digits.count
        }
        
        guard index < bytes.count else {
            return true
        }
        guard [UInt8(ascii: "/"), UInt8(ascii: "?"), UInt8(ascii: "#")].contains(bytes[index]) else {
            return false
        }
        
        var remaining = bytes[index...].makeIterator()
        var fragmentCount = 0
        while let byte = remaining.next() {
            switch byte {
            case UInt8(ascii: "%"):
                guard let high = remaining.next(), let low = remaining.next(), isHexDigit(high), isHexDigit(low) else {
                    return false
                }
            case UInt8(ascii: "#"):
                fragmentCount += 1
                guard fragmentCount == 1 else {
                    return false
                }
            default:
                guard urlCharacters.contains(byte) else {
                    return false
                }
            }
        }
        return true
    }
    
    private static func hostEnd(in bytes: [UInt8], from start: Int) -> Int? {
        var index = start
        while true {
            let labelStart = index
            while index < bytes.count, isDigit(bytes[index]) || isLetter(bytes[index]) || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index > labelStart, bytes[labelStart] != UInt8(ascii: "-"), bytes[index - 1] != UInt8(ascii: "-") else {
                return nil
            }
            guard index < bytes.count, bytes[index] == UInt8(ascii: ".") else {
                return index
            }
            index += 1
        }
    }
    
    /// WHATWG input preprocessing, which SwiftSoup skips: CRLF and lone CR become LF.
    private static func preprocessed(_ html: String) -> String {
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in html.unicodeScalars {
            if scalar != "\n" || previous != "\r" {
                scalars.append(scalar == "\r" ? "\n" : scalar)
            }
            previous = scalar
        }
        return String(scalars)
    }
    
    /// The `<a>` that ends the body once trailing White_Space text and `<br>` are skipped, looking inside trailing `<p>`, `<div>` and `<span>`.
    private static func trailingLink(in body: Element) -> Element? {
        var element = body
        while let last = element.getChildNodes().last(where: { !isTrailingFiller($0) }) as? Element {
            switch last.tagNameNormal() {
            case "a":
                return last
            case "p", "div", "span":
                element = last
            default:
                return nil
            }
        }
        return nil
    }
    
    private static func isTrailingFiller(_ node: Node) -> Bool {
        if let text = node as? TextNode {
            return text.getWholeText().unicodeScalars.allSatisfy(\.isGuaWhiteSpace)
        }
        return (node as? Element)?.tagNameNormal() == "br"
    }
    
    /// The DOM `textContent` the other clients compare with the label, gathered without recursion.
    private static func textContent(of element: Element) -> String {
        var text = ""
        var stack: [Node] = [element]
        while let node = stack.popLast() {
            if let textNode = node as? TextNode {
                text += textNode.getWholeText()
            } else {
                stack.append(contentsOf: node.getChildNodes().reversed())
            }
        }
        return text
    }
    
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        [UInt8(ascii: "\t"), UInt8(ascii: "\n"), 0x0C, UInt8(ascii: "\r"), UInt8(ascii: " ")].contains(byte)
    }
    
    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
    
    private static func isLowercaseLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }
    
    private static func isLetter(_ byte: UInt8) -> Bool {
        isLowercaseLetter(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
    }
    
    private static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    }
}

nonisolated protocol GuaMessageActionsContent {
    var formattedBody: AttributedString? { get }
    var formattedBodyHTMLString: String? { get }
    var actions: [GuaMessageAction] { get set }
    var formattedBodyWithoutFallback: AttributedString? { get set }
}

nonisolated extension GuaMessageActionsContent {
    /// The body as the bubble shows it. Copy, selection and reply previews read `formattedBody` instead.
    var bubbleFormattedBody: AttributedString? {
        formattedBodyWithoutFallback ?? formattedBody
    }
    
    /// False when the fallback link was the whole body, which leaves only the buttons.
    var hasBubbleBody: Bool {
        formattedBodyWithoutFallback?.characters.isEmpty != true
    }
    
    /// `formattedBodyHTMLString` is the SDK's sanitised copy, not the raw body the spec reads, so only its presence gates reading the JSON.
    func addingGuaMessageActions(latestJSON: @autoclosure () -> String?) -> Self {
        guard formattedBodyHTMLString != nil, let json = latestJSON() else {
            return self
        }
        
        let result = GuaMessageActionParser.parse(eventJSON: json)
        guard !result.actions.isEmpty else {
            return self
        }
        
        var content = self
        content.actions = result.actions
        if let fallback = result.fallback, let formattedBody {
            content.formattedBodyWithoutFallback = fallback.removingTrailingLink(from: formattedBody)
        }
        return content
    }
}

nonisolated extension TextRoomTimelineItemContent: GuaMessageActionsContent { }

nonisolated extension NoticeRoomTimelineItemContent: GuaMessageActionsContent { }

nonisolated extension RoomTimelineItemProtocol {
    var guaMessageActions: [GuaMessageAction] {
        switch self {
        case let item as TextRoomTimelineItem: item.content.actions
        case let item as NoticeRoomTimelineItem: item.content.actions
        default: []
        }
    }
}

private nonisolated extension String {
    /// Swift's `==` also matches canonically equivalent strings, but the spec compares exactly.
    func isIdentical(to other: String) -> Bool {
        unicodeScalars.elementsEqual(other.unicodeScalars)
    }
    
    func trimmingGuaWhiteSpace() -> String {
        guard let first = unicodeScalars.firstIndex(where: { !$0.isGuaWhiteSpace }),
              let last = unicodeScalars.lastIndex(where: { !$0.isGuaWhiteSpace }) else {
            return ""
        }
        return String(unicodeScalars[first...last])
    }
}

private nonisolated extension Character {
    var isGuaWhiteSpace: Bool {
        unicodeScalars.allSatisfy(\.isGuaWhiteSpace)
    }
}

private nonisolated extension Unicode.Scalar {
    /// Unicode general category Cc.
    var isGuaControl: Bool {
        value <= 0x1F || (0x7F...0x9F).contains(value)
    }
    
    /// U+FDD0 to U+FDEF and the last two code points of every plane. jsoup reads a literal U+FFFF as the end of its input.
    var isGuaNoncharacter: Bool {
        (0xFDD0...0xFDEF).contains(value) || value & 0xFFFE == 0xFFFE
    }
    
    /// Unicode White_Space, spelled out because the spec trims with exactly this set; `.whitespacesAndNewlines` adds U+200B.
    var isGuaWhiteSpace: Bool {
        switch value {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }
}
