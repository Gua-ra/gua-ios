//
// Copyright 2026 Gua
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import Foundation
import MatrixRustSDK
import MatrixRustSDKMocks
import Testing

/// The shared fixtures under `UnitTests/Resources` are the cross-client contract for `global.gua.actions`
/// and stay byte-identical to the copies in the other Gua clients.
struct GuaMessageActionTests {
    nonisolated static let fixtures = loadFixtures()
    /// Passes every rule but rule 1, so the markup around it alone decides.
    nonisolated static let link = "<a href=\"https://bills.example.org/s\">View statement</a>"
    /// Rule 1 lets these nest in any order.
    nonisolated static let wrapperNames = ["div", "blockquote", "span", "b", "i", "em", "strong", "u", "s", "code", "del", "sub", "sup"]
    
    @Test
    func everyFixtureDecodes() {
        #expect(!Self.fixtures.cases.isEmpty, "The shared fixtures are missing from the test bundle.")
        #expect(Self.fixtures.failures.isEmpty, "Shared fixtures that could not be decoded: \(Self.fixtures.failures)")
    }
    
    @Test(arguments: GuaMessageActionTests.fixtures.cases)
    func parser(fixture: Fixture) throws {
        let result = try parse(content: fixture.content)
        
        #expect(result.actions.map(ExpectedAction.init) == fixture.expectedActions)
        #expect((result.fallback != nil) == fixture.fallbackHidden)
    }
    
    @Test(arguments: GuaMessageActionTests.fixtures.cases)
    func timelineItem(fixture: Fixture) throws {
        let displayedContent = fixture.content["m.new_content"]?.object ?? fixture.content
        let builder = AttributedStringBuilder(cacheKey: "GuaMessageActionTests", mentionBuilder: MentionBuilder())
        let msgType = try #require(messageType(of: displayedContent), "Unsupported msgtype in \(fixture.name)")
        let (proxy, _) = try makeItem(msgType: msgType, latestJSON: eventJSON(content: fixture.content))
        
        let item = try #require(makeFactory(builder: builder).buildTimelineItem(for: proxy, isDM: false))
        let itemContent = actionsContent(of: item)
        
        #expect(item.guaMessageActions.map(ExpectedAction.init) == fixture.expectedActions)
        #expect((itemContent?.formattedBodyWithoutFallback != nil) == fixture.fallbackHidden)
        
        if let itemContent, let html = itemContent.formattedBodyHTMLString {
            #expect(html == displayedContent["formatted_body"]?.string)
            #expect(itemContent.formattedBody == builder.fromHTML(html), "Copy, selection and replies keep the original body.")
        }
        
        if fixture.fallbackHidden, let originalBody = itemContent?.formattedBody, let shownBody = itemContent?.formattedBodyWithoutFallback {
            let original = String(originalBody.characters)
            let shown = String(shownBody.characters)
            #expect(original.hasPrefix(shown))
            #expect(shown.count < original.count)
            #expect(fixture.expectedActions.allSatisfy { !shown.hasSuffix($0.label) })
            #expect(shown.last?.isWhitespace != true)
        }
    }
    
    @Test
    func factoryAddsActionsAndHidesTheTrailingLink() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let html = "<strong>August statement</strong><br><a href=\"\(url)\">View statement</a>"
        let builder = AttributedStringBuilder(cacheKey: "GuaMessageActionFactoryTests", mentionBuilder: MentionBuilder())
        let cachedBody = try #require(builder.fromHTML(html))
        let (proxy, lazyProvider) = try makeItem(msgType: .text(content: .init(body: "", formatted: .init(format: .html, body: html))),
                                                 latestJSON: eventJSON(html: html, actions: [("View statement", url)]))
        
        let item = try #require(makeFactory(builder: builder).buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
        
        #expect(lazyProvider.latestJsonCallsCount == 1)
        #expect(item.content.actions.map(\.rawURL) == [url])
        #expect(item.content.formattedBodyWithoutFallback.map { String($0.characters) } == "August statement")
        #expect(item.content.formattedBody == cachedBody, "Copy, selection and replies keep the original body.")
        #expect(item.content.formattedBodyHTMLString == html)
        #expect(item.links.isEmpty, "A link replaced by a button gets no preview.")
        #expect(builder.fromHTML(html) == cachedBody, "The builder's cached string must not change.")
    }
    
    @Test
    func factoryAddsActionsToANotice() throws {
        let url = "https://ci.example.org/builds/7"
        let html = "Build finished<br><a href=\"\(url)\">View build</a>"
        let builder = AttributedStringBuilder(cacheKey: "GuaMessageActionNoticeTests", mentionBuilder: MentionBuilder())
        let (proxy, _) = try makeItem(msgType: .notice(content: .init(body: "", formatted: .init(format: .html, body: html))),
                                      latestJSON: eventJSON(html: html, actions: [("View build", url)], msgType: "m.notice"))
        
        let item = try #require(makeFactory(builder: builder).buildTimelineItem(for: proxy, isDM: false) as? NoticeRoomTimelineItem)
        
        #expect(item.guaMessageActions.map(\.rawURL) == [url])
        #expect(item.content.formattedBodyWithoutFallback.map { String($0.characters) } == "Build finished")
        #expect(item.content.formattedBody == builder.fromHTML(html))
    }
    
    @Test
    func factorySkipsTheEventJSONWithoutAnHTMLBody() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let (proxy, lazyProvider) = try makeItem(msgType: .text(content: .init(body: "View statement: \(url)", formatted: nil)),
                                                 latestJSON: eventJSON(html: "<a href=\"\(url)\">View statement</a>", actions: [("View statement", url)]))
        
        let item = try #require(makeFactory().buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
        
        #expect(!lazyProvider.latestJsonCalled)
        #expect(item.content.actions.isEmpty)
    }
    
    @Test
    func factoryHidesNothingWhenTheRenderedBodyLacksTheLink() throws {
        let fixture = try #require(Self.fixtures.cases.first { $0.name == "trailing link becomes the button" })
        // The bubble renders the SDK's sanitised copy of the body, while the actions come from the raw event.
        let renderedHTML = "<strong>August statement</strong><br>Total: <strong>$10.00</strong>"
        let (proxy, _) = try makeItem(msgType: .text(content: .init(body: "x", formatted: .init(format: .html, body: renderedHTML))),
                                      latestJSON: eventJSON(content: fixture.content))
        
        let item = try #require(makeFactory().buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
        
        #expect(item.content.actions.map(\.rawURL) == ["https://bills.example.org/statement/2026-08"])
        #expect(item.content.formattedBodyWithoutFallback == nil)
    }
    
    @Test
    func factoryWithoutEventJSONKeepsTheLink() throws {
        let html = "Text<br><a href=\"https://bills.example.org/statement/2026-08\">View statement</a>"
        let (proxy, _) = makeItem(msgType: .text(content: .init(body: "", formatted: .init(format: .html, body: html))), latestJSON: nil)
        
        let item = try #require(makeFactory().buildTimelineItem(for: proxy, isDM: false) as? TextRoomTimelineItem)
        
        #expect(item.content.actions.isEmpty)
        #expect(item.links == ["https://bills.example.org/statement/2026-08"])
    }
    
    @Test(arguments: ["<a href=\"https://shop.example.org/orders/42\">View order</a>",
                      "<p><a href=\"https://shop.example.org/orders/42\">View order</a><br></p>"])
    func aBodyThatIsOnlyTheLinkShowsOnlyTheButtons(html: String) throws {
        let url = "https://shop.example.org/orders/42"
        let body = try #require(AttributedStringBuilder(cacheKey: "GuaMessageActionLinkOnlyTests", mentionBuilder: MentionBuilder()).fromHTML(html))
        let json = try eventJSON(html: html, actions: [("View order", url)])
        
        let content = TextRoomTimelineItemContent(body: "View order", formattedBody: body, formattedBodyHTMLString: html)
            .addingGuaMessageActions(latestJSON: json)
        
        #expect(content.actions.map(\.rawURL) == [url])
        #expect(!content.hasBubbleBody)
        #expect(content.formattedBody == body)
    }
    
    @Test
    func labelPosingAsAnotherLink() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let html = "Text<br><a href=\"\(url)\">other.example.org</a>"
        let builder = AttributedStringBuilder(cacheKey: "GuaMessageActionPhishingTests", mentionBuilder: MentionBuilder())
        let body = try #require(builder.fromHTML(html))
        let json = try eventJSON(html: html, actions: [("other.example.org", url)])
        
        let content = TextRoomTimelineItemContent(body: "", formattedBody: body, formattedBodyHTMLString: html)
            .addingGuaMessageActions(latestJSON: json)
        
        let action = try #require(content.actions.first)
        #expect(content.formattedBodyWithoutFallback.map { String($0.characters) } == "Text", "The rewritten link should still be hidden.")
        #expect(action.urlToOpen.requiresConfirmation)
        #expect(action.urlToOpen.confirmationParameters?.internalURL == action.url)
        #expect(GuaMessageAction(label: "View statement", rawURL: url, url: action.url).urlToOpen == action.url)
    }
    
    @Test
    func anHrefOnlyCanonicallyEquivalentToTheURLDoesNotMatch() throws {
        let html = "Text<br><a href=\"https://bills.example.org/\u{212A}\">View statement</a>"
        let content = fixtureContent(html: html, actions: [("View statement", "https://bills.example.org/K")])
        
        #expect(try parse(content: content).actions.isEmpty)
    }
    
    @Test(arguments: ["\u{FEFF}", #"\ufeff"#])
    func aLabelThatStartsWithAByteOrderMarkKeepsIt(mark: String) {
        let result = GuaMessageActionParser.parse(eventJSON: serverEventJSON(label: mark + "View statement"))
        
        #expect(result.actions.map(\.label) == ["\u{FEFF}View statement"])
        #expect(result.actions.map(\.rawURL) == ["https://bills.example.org/s"])
        #expect(result.fallback == nil, "The link's text has no U+FEFF, so the link stays.")
    }
    
    @Test(arguments: ["\u{FEFF}", #"\ufeff"#])
    func aURLThatStartsWithAByteOrderMarkGetsNoAction(mark: String) {
        #expect(GuaMessageActionParser.parse(eventJSON: serverEventJSON(url: mark + "https://bills.example.org/s")).actions.isEmpty)
    }
    
    @Test(arguments: ["\u{FEFF}", #"\ufeff"#])
    func anActionsKeyThatStartsWithAByteOrderMarkIsIgnored(mark: String) {
        #expect(GuaMessageActionParser.parse(eventJSON: serverEventJSON(key: mark + GuaMessageActionParser.contentKey)).actions.isEmpty)
    }
    
    @Test
    func fieldsTheRulesNeverReadDoNotRejectTheEvent() {
        let unsigned = String(repeating: #"{"a":[1.5e300,-0.0,null,true,"#, count: 200) + "0" + String(repeating: "]}", count: 200)
        let fields = #""origin_server_ts":1731800000000,"age":18446744073709551616,"unsigned":\#(unsigned),"#
        
        #expect(GuaMessageActionParser.parse(eventJSON: serverEventJSON(fields: fields)).actions.map(\.rawURL) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["null,", "1,", "true,", #""open_url","#, "[],", #"{"type":"open_url","label":5,"url":"https://bills.example.org/s"},"#])
    func anElementOfAnotherShapeIsDroppedOnItsOwn(element: String) {
        #expect(GuaMessageActionParser.parse(eventJSON: serverEventJSON(elementsBefore: element)).actions.map(\.rawURL) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["Text<br>" + link,
                      "Text<br><a href='https://bills.example.org/s'>View statement</a>",
                      "Text<br><a\thref=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a\nhref=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a\u{0C}href=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a\rhref=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a\r\nhref=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a  href=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a \t\n\u{0C}\r href='https://bills.example.org/s'>View statement</a>",
                      "Text<br>Total<br/>Due<br />" + link,
                      "Text\t\n\u{0C}\r\nTotal\r<br>" + link,
                      "&amp;&lt;&gt;&quot;&apos;&nbsp;&#65;&#0000065;&#x41;&#X000041;&#X1d11e;&#1114109;&#x10FFFD;&#xFFFD;<br>" + link,
                      "Text<br><a href=\"https:&#47;&#x2F;bills.example.org&#X2f;&#0000115;\">View statement</a>",
                      "<a href=\"https://bills.example.org/o?a=1&amp;b=2\">Order</a><br>" + link,
                      "Total > $5, a = \"b\" / 'c'<br>" + link,
                      "<a href=\"x'y\">Other</a> <a href='x\"y'>Other</a> <a href=\"\">Other</a> <a>Other</a><br>" + link])
    func tagsInTheStrictFormKeepTheActions(html: String) throws {
        #expect(try keptURLs(html: html) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["<ul><li>August<ol><li>statement</li></ol></li></ul>" + link,
                      "<b><p>August statement</p></b>" + link,
                      "Text<br><a href=\"https://bills.example.org/s\"><p>View statement</p></a>",
                      "<h1>August</h1><h2>statement</h2>" + link,
                      "<h1><p>August</p></h1>" + link,
                      "<p>August <b>statement</b> " + link + "</p>",
                      nested(wrappers(19), around: link),
                      nested(wrappers(20), around: "Total") + link,
                      nested(["b", "i", "b", "i", "b"], around: "Total") + link,
                      "<b><b><b>Total</b></b></b><b>Due</b>" + link,
                      String(repeating: "<i></i>", count: 99) + String(repeating: "<br>", count: 100) + link,
                      "<ul><li>Total</li></ul>" + link,
                      "<ol><li>Total</li></ol>" + link])
    func elementsNestedAsWrittenKeepTheActions(html: String) throws {
        #expect(try keptURLs(html: html) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["b", "blockquote", "code", "del", "div", "em", "h1", "h2", "h3", "h4", "h5", "h6", "i", "p", "s", "span", "strong", "sub", "sup", "u"])
    func everyOtherElementOfRule1KeepsTheActions(name: String) throws {
        #expect(try keptURLs(html: "<\(name)>Total</\(name)>" + Self.link) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["<!-- Total -->" + link,
                      "<![CDATA[Total]]>" + link,
                      "<?BR>" + link,
                      link + "<?",
                      "<!DOCTYPE html>" + link,
                      "<B>Total</B>" + link,
                      "Text<br><A href=\"https://bills.example.org/s\">View statement</A>",
                      "Text<br><a HREF=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a href=https://bills.example.org/s>View statement</a>",
                      "Text<br><a href = \"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a href =\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a href= \"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a href=\"https://bills.example.org/s\" href=\"https://bills.example.org/s\">View statement</a>",
                      "Text<br><a href=\"https://bills.example.org/s\" title=\"Statement\">View statement</a>",
                      "Text<br><a title=\"Statement\" href=\"https://bills.example.org/s\">View statement</a>",
                      "<strong class=\"x\">Total</strong>" + link,
                      "<span data-msc4286-external-payment-details>" + link + "</span>",
                      "<a href=\"x>\">Other</a>" + link,
                      "<a href=\"x<\">Other</a>" + link,
                      "<a href=\"x&y\">Other</a>" + link,
                      "<a >Other</a>" + link,
                      "<a href>Other</a>" + link,
                      "Text<br><a href=\"https://bills.example.org/s\" >View statement</a>",
                      "Text<br><a href=\"https://bills.example.org/s\"/>View statement</a>",
                      "<strong/>Total" + link,
                      "<span / >Total</span>" + link,
                      "<strong >Total</strong>" + link,
                      "<strong>Total</strong >" + link,
                      "<a href=\"https://bills.example.org/o\">Order</a href=\"x\"><br>" + link,
                      "Text<br >" + link,
                      "Text<br/ >" + link,
                      "Text<br  />" + link,
                      "Text<BR>" + link,
                      link + "</br>",
                      "Total < $20<br>" + link,
                      link + "<",
                      link + "</",
                      link + "<a href=\"x\"",
                      link + "<a href=\"x",
                      "<b1>Total</b1>" + link,
                      "<h7>Total</h7>" + link,
                      "<textarea>Total</textarea>" + link,
                      "<bloc\u{212A}quote>Total</bloc\u{212A}quote>" + link,
                      "Total</table>" + link,
                      "<b\u{A0}>Total</b>" + link])
    func tagsOutsideTheStrictFormGetNoAction(html: String) throws {
        #expect(try keptURLs(html: html).isEmpty)
    }
    
    @Test(arguments: ["<b>August <i>statement</b></i>" + link,
                      "<b>August <i>statement</b><br>" + link,
                      "<b>Total<br>" + link,
                      "Total</b><br>" + link,
                      "<b>Total</i></b>" + link,
                      "<a href=\"https://bills.example.org/o\">Other <b>" + link + "</b></a>",
                      "<h1>August <b><h2>statement</h2></b></h1>" + link,
                      "<li>Total</li>" + link,
                      "<ul><b><li>Total</li></b></ul>" + link,
                      "<ul><li>Total<li>Due</li></li></ul>" + link,
                      nested(wrappers(20), around: link),
                      nested(wrappers(21), around: "Total") + link,
                      nested(["b", "i", "b", "i", "b", "i", "b"], around: "Total") + link,
                      String(repeating: "<i></i>", count: 100) + String(repeating: "<br>", count: 100) + link])
    func nestingThatParsersRebuildGetsNoAction(html: String) throws {
        #expect(try keptURLs(html: html).isEmpty)
    }
    
    @Test(arguments: ["blockquote", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ol", "p", "ul"])
    func aBlockAnywhereInsideAParagraphGetsNoAction(name: String) throws {
        #expect(try keptURLs(html: "<p>Total <b><\(name)></\(name)></b></p>" + Self.link).isEmpty)
    }
    
    @Test(arguments: ["ul", "ol"], ["\t", "\n", "\u{0C}", "\r", " ", "\r\n", " \r\n\t "])
    func whitespaceDirectlyInAListKeepsTheActions(list: String, whitespace: String) throws {
        let html = "<\(list)>" + whitespace + "<li>Total</li>" + whitespace + "<li>Due <ul><li>August</li></ul></li>" + whitespace + "</\(list)>" + Self.link
        
        #expect(try keptURLs(html: html) == ["https://bills.example.org/s"])
    }
    
    @Test(arguments: ["ul", "ol"], ["Total", "\u{A0}", "\u{3000}", "&#32;", "&nbsp;", "&amp;", "<br>", "<br/>", "<br />", "<a href=\"https://bills.example.org/o\">Order</a>",
                                    link, "<b>Total</b>", "<p>Total</p>", "<ul><li>Total</li></ul>", "<ol><li>Total</li></ol>"])
    func anythingElseDirectlyInAListGetsNoAction(list: String, child: String) throws {
        #expect(try keptURLs(html: "<\(list)>" + child + "<li>Total</li></\(list)>" + Self.link).isEmpty)
        #expect(try keptURLs(html: "<\(list)><li>Total</li>" + child + "</\(list)>" + Self.link).isEmpty)
    }
    
    @Test(arguments: ["&#9;", "&#x9F;", "&#0;", "&#xD800;", "&#1114112;", "&#x110000;", "&#00000065;", "&#x0000041;", "&#x;", "&#;", "&#65", "&nbsp",
                      "&AMP;", "&times;", " & ", "&", "\u{0}", "\u{0B}", "\u{1B}", "\u{7F}", "\u{85}", "\u{9F}"])
    func referencesAndControlsOutsideRule1GetNoAction(text: String) throws {
        #expect(try keptURLs(html: "Text" + text + "<br>" + Self.link).isEmpty)
    }
    
    @Test(arguments: [0xFDCF, 0xFDF0, 0xFFFD, 0x1FFFD, 0x10FFFD] as [UInt32])
    func scalarsNextToTheNoncharactersKeepTheActions(value: UInt32) throws {
        for html in try noncharacterBodies(value) {
            #expect(try keptURLs(html: html) == ["https://bills.example.org/s"], "\(html)")
        }
    }
    
    @Test(arguments: [0xFDD0, 0xFDEF, 0xFFFE, 0xFFFF, 0x1FFFE, 0x1FFFF, 0x10FFFE, 0x10FFFF] as [UInt32])
    func noncharactersGetNoAction(value: UInt32) throws {
        for html in try noncharacterBodies(value) {
            #expect(try keptURLs(html: html).isEmpty, "\(html)")
        }
    }
    
    @Test
    func aLoneCarriageReturnReadsAsALineFeed() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let content = fixtureContent(html: "Text<br><a href=\"\(url)\">View\rstatement</a>", actions: [("View\nstatement", url)])
        
        #expect(try parse(content: content).fallback?.rawURL == url)
    }
    
    @Test
    func anAdjacentLinkToTheSameURLStaysDisplayed() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let html = "<a href=\"\(url)\">Other</a><a href=\"\(url)\">View statement</a>"
        let body = try #require(AttributedStringBuilder(cacheKey: "GuaMessageActionAdjacentLinkTests", mentionBuilder: MentionBuilder()).fromHTML(html))
        let json = try eventJSON(html: html, actions: [("View statement", url)])
        
        let content = TextRoomTimelineItemContent(body: "", formattedBody: body, formattedBodyHTMLString: html)
            .addingGuaMessageActions(latestJSON: json)
        
        #expect(content.formattedBodyWithoutFallback.map { String($0.characters) } == "Other")
        #expect(content.formattedBody == body)
    }
    
    @Test
    func anAdjacentLinkToTheSameURLStaysDisplayedWhenTheLabelSpansLines() throws {
        let url = "https://bills.example.org/statement/2026-08"
        let html = "<a href=\"\(url)\">Statement</a><a href=\"\(url)\">View\r\nstatement</a>"
        let body = try #require(AttributedStringBuilder(cacheKey: "GuaMessageActionAdjacentLineTests", mentionBuilder: MentionBuilder()).fromHTML(html))
        let json = try eventJSON(html: html, actions: [("View\nstatement", url)])
        
        let content = TextRoomTimelineItemContent(body: "", formattedBody: body, formattedBodyHTMLString: html)
            .addingGuaMessageActions(latestJSON: json)
        
        #expect(content.formattedBodyWithoutFallback.map { String($0.characters) } == "Statement")
    }
    
    @Test
    func aLinkRunThatDoesNotEndWithTheLabelStaysDisplayed() throws {
        let url = try #require(URL(string: "https://bills.example.org/statement/2026-08"))
        var body = AttributedString("Pay now")
        body.link = url
        
        #expect(GuaMessageAction(label: "View statement", rawURL: url.absoluteString, url: url).removingTrailingLink(from: body) == nil)
    }
    
    private func makeFactory(builder: AttributedStringBuilder = AttributedStringBuilder(mentionBuilder: MentionBuilder())) -> RoomTimelineItemFactory {
        RoomTimelineItemFactory(userID: "@alice:example.org",
                                attributedStringBuilder: builder,
                                stateEventStringBuilder: RoomStateEventStringBuilder(userID: "@alice:example.org"))
    }
    
    private func makeItem(msgType: MessageType, latestJSON: String?) -> (EventTimelineItemProxy, LazyTimelineItemProviderSDKMock) {
        let lazyProvider = LazyTimelineItemProviderSDKMock()
        lazyProvider.containsOnlyEmojisReturnValue = false
        lazyProvider.getShieldsStrictReturnValue = ShieldState.none
        lazyProvider.latestJsonReturnValue = latestJSON
        
        let content = TimelineItemContent.msgLike(content: .init(kind: .message(content: .init(msgType: msgType,
                                                                                               body: "",
                                                                                               isEdited: false,
                                                                                               mentions: nil)),
                                                                 inReplyTo: nil,
                                                                 threadRoot: nil,
                                                                 threadSummary: nil))
        let item = EventTimelineItem(isRemote: true,
                                     eventOrTransactionId: .eventId(eventId: "$event"),
                                     sender: "@bot:example.org",
                                     senderProfile: .pending,
                                     forwarder: nil,
                                     forwarderProfile: nil,
                                     isOwn: false,
                                     isEditable: false,
                                     content: content,
                                     reactions: [],
                                     eventTypeRaw: nil,
                                     timestamp: 0,
                                     localSendState: nil,
                                     editSendState: nil,
                                     redactionSendState: nil,
                                     redactionReason: nil,
                                     localCreatedAt: nil,
                                     readReceipts: [:],
                                     origin: nil,
                                     canBeRepliedTo: true,
                                     lazyProvider: lazyProvider)
        
        return (EventTimelineItemProxy(item: item, uniqueID: .init("0")), lazyProvider)
    }
    
    private func messageType(of content: [String: JSONValue]) -> MessageType? {
        let body = content["body"]?.string ?? ""
        let formatted = content["formatted_body"]?.string.map { html in
            let format = content["format"]?.string ?? ""
            return FormattedBody(format: format == "org.matrix.custom.html" ? .html : .unknown(format: format), body: html)
        }
        
        switch content["msgtype"]?.string {
        case "m.text": return .text(content: TextMessageContent(body: body, formatted: formatted))
        case "m.notice": return .notice(content: NoticeMessageContent(body: body, formatted: formatted))
        case "m.emote": return .emote(content: EmoteMessageContent(body: body, formatted: formatted))
        default: return nil
        }
    }
    
    private func actionsContent(of item: RoomTimelineItemProtocol) -> (any GuaMessageActionsContent)? {
        switch item {
        case let item as TextRoomTimelineItem: return item.content
        case let item as NoticeRoomTimelineItem: return item.content
        default: return nil
        }
    }
    
    private func keptURLs(html: String) throws -> [String] {
        try parse(content: fixtureContent(html: html, actions: [("View statement", "https://bills.example.org/s")])).actions.map(\.rawURL)
    }
    
    /// The scalar written as is, as a decimal and as a hex reference, each in the text and inside an href.
    private func noncharacterBodies(_ value: UInt32) throws -> [String] {
        let scalar = try #require(Unicode.Scalar(value))
        let spellings = [String(scalar), "&#\(value);", "&#x\(String(value, radix: 16, uppercase: true));"]
        return spellings.flatMap { written -> [String] in
            ["Text\(written)<br>\(Self.link)", "<a href=\"https://bills.example.org/o?\(written)\">Order</a><br>\(Self.link)"]
        }
    }
    
    /// Opens `count` elements with no name more than twice.
    private nonisolated static func wrappers(_ count: Int) -> [String] {
        Array((wrapperNames + wrapperNames).prefix(count))
    }
    
    private nonisolated static func nested(_ names: [String], around inner: String) -> String {
        names.map { "<\($0)>" }.joined() + inner + names.reversed().map { "</\($0)>" }.joined()
    }
    
    private func parse(content: [String: JSONValue]) throws -> GuaMessageActionParser.Result {
        try GuaMessageActionParser.parse(content: JSONDecoder().decode(GuaMessageActionParser.Content.self, from: JSONEncoder().encode(content)))
    }
    
    private func fixtureContent(html: String, actions: [(label: String, url: String)], msgType: String = "m.text") -> [String: JSONValue] {
        ["msgtype": .string(msgType),
         "body": "",
         "format": "org.matrix.custom.html",
         "formatted_body": .string(html),
         GuaMessageActionParser.contentKey: .array(actions.map { .object(["type": "open_url", "label": .string($0.label), "url": .string($0.url)]) })]
    }
    
    private func eventJSON(html: String, actions: [(label: String, url: String)], msgType: String = "m.text") throws -> String {
        try eventJSON(content: fixtureContent(html: html, actions: actions, msgType: msgType))
    }
    
    private func eventJSON(content: [String: JSONValue]) throws -> String {
        let data = try JSONEncoder().encode(["type": "m.room.message", "content": JSONValue.object(content)])
        return try #require(String(data: data, encoding: .utf8))
    }
    
    /// Event JSON as written by hand, so a test can put `\ufeff` itself into the text.
    private func serverEventJSON(key: String = GuaMessageActionParser.contentKey, label: String = "View statement",
                                 url: String = "https://bills.example.org/s", elementsBefore: String = "", fields: String = "") -> String {
        #"{"type":"m.room.message",\#(fields)"content":{"msgtype":"m.text","body":"x","format":"org.matrix.custom.html","#
            + #""formatted_body":"Text<br><a href=\"https://bills.example.org/s\">View statement</a>","#
            + #""\#(key)":[\#(elementsBefore){"type":"open_url","label":"\#(label)","url":"\#(url)"}]}}"#
    }
}

extension GuaMessageActionTests {
    nonisolated struct ExpectedAction: Decodable, Equatable, Sendable {
        let label: String
        let url: String
        
        init(_ action: GuaMessageAction) {
            label = action.label
            url = action.rawURL
        }
    }
    
    /// Any JSON value. Fixtures go through this rather than JSONSerialization, which drops a leading U+FEFF from every string and key.
    nonisolated enum JSONValue: Codable, Sendable, ExpressibleByStringLiteral {
        case string(String)
        case number(Double)
        case bool(Bool)
        case null
        case array([JSONValue])
        case object([String: JSONValue])
        
        var string: String? {
            if case let .string(string) = self {
                string
            } else {
                nil
            }
        }
        
        var object: [String: JSONValue]? {
            if case let .object(object) = self {
                object
            } else {
                nil
            }
        }
        
        init(stringLiteral value: String) {
            self = .string(value)
        }
        
        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let string = try? container.decode(String.self) {
                self = .string(string)
            } else if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else if let array = try? container.decode([JSONValue].self) {
                self = .array(array)
            } else {
                self = try .object(container.decode([String: JSONValue].self))
            }
        }
        
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(string): try container.encode(string)
            case let .number(number): try container.encode(number)
            case let .bool(bool): try container.encode(bool)
            case .null: try container.encodeNil()
            case let .array(array): try container.encode(array)
            case let .object(object): try container.encode(object)
            }
        }
    }
    
    nonisolated struct Fixture: Sendable, CustomTestStringConvertible {
        let name: String
        let content: [String: JSONValue]
        let expectedActions: [ExpectedAction]
        let fallbackHidden: Bool
        
        var testDescription: String {
            name
        }
        
        /// Fails on anything the shared format does not allow, so a malformed case is reported instead of skipped.
        init(entry: JSONValue) throws {
            guard let entry = entry.object,
                  let name = entry["name"]?.string,
                  let content = entry["content"]?.object,
                  let expect = entry["expect"] else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "A case needs a name, a content object and an expect object."))
            }
            let expectation = try JSONDecoder().decode(Expectation.self, from: JSONEncoder().encode(expect))
            
            self.name = name
            self.content = content
            expectedActions = expectation.actions
            fallbackHidden = expectation.fallbackHidden
        }
        
        private nonisolated struct Expectation: Decodable {
            let actions: [ExpectedAction]
            let fallbackHidden: Bool
            
            enum CodingKeys: String, CodingKey {
                case actions
                case fallbackHidden = "fallback_hidden"
            }
        }
    }
    
    nonisolated struct Fixtures: Sendable {
        var cases = [Fixture]()
        var failures = [String]()
    }
    
    private final nonisolated class BundleToken { }
    
    private nonisolated static func loadFixtures() -> Fixtures {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "gua-message-actions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            return Fixtures(failures: ["The fixture file is missing or is not a JSON array."])
        }
        
        var fixtures = Fixtures()
        for (index, entry) in entries.enumerated() {
            do {
                try fixtures.cases.append(Fixture(entry: entry))
            } catch {
                fixtures.failures.append("case \(index): \(error)")
            }
        }
        return fixtures
    }
}
