import Foundation
import Testing
@testable import MacshotCore

private func fixedDate() -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 5
    components.day = 22
    components.hour = 14
    components.minute = 31
    components.second = 8
    components.nanosecond = 7_000_000
    return Calendar.current.date(from: components)!
}

private func makeContext() -> FilenameTemplate.Context {
    var context = FilenameTemplate.Context()
    context.date = fixedDate()
    context.windowTitle = "Grafana – Dashboards"
    context.appName = "Safari"
    context.mode = "region"
    context.host = "mymac"
    context.user = "deme"
    context.counter = 7
    context.counterPadding = 4
    context.uuidProvider = { "UUID-FIXED" }
    context.randomProvider = { String(repeating: "r", count: $0) }
    return context
}

@Test
func dateTokensExpand() {
    let result = FilenameTemplate.expand(
        "Screenshot_%y-%mo-%d_%h-%mi-%s.%ms", context: makeContext()
    )
    #expect(result == "Screenshot_2026-05-22_14-31-08.007")
}

@Test
func modeDoesNotCollideWithMonthToken() {
    let result = FilenameTemplate.expand("%mode-%mo", context: makeContext())
    #expect(result == "region-05")
}

@Test
func counterIsPadded() {
    let result = FilenameTemplate.expand("%counter", context: makeContext())
    #expect(result == "0007")

    var wide = makeContext()
    wide.counter = 123456
    #expect(FilenameTemplate.expand("%counter", context: wide) == "123456")
}

@Test
func windowAndAppAreSanitized() {
    let result = FilenameTemplate.expand("%window__%app", context: makeContext())
    #expect(result == "Grafana___Dashboards__Safari")
}

@Test
func uuidAndRandUseProviders() {
    let result = FilenameTemplate.expand("%uuid-%rand:6", context: makeContext())
    #expect(result == "UUID-FIXED-rrrrrr")
}

@Test
func hostAndUserExpand() {
    let result = FilenameTemplate.expand("%host-%user", context: makeContext())
    #expect(result == "mymac-deme")
}

@Test
func unknownTokensStayLiteral() {
    let result = FilenameTemplate.expand("100%zoom %q %rand %rand:x", context: makeContext())
    #expect(result == "100%zoom %q %rand %rand:x")
}

@Test
func trailingPercentStaysLiteral() {
    #expect(FilenameTemplate.expand("name%", context: makeContext()) == "name%")
}

@Test
func defaultRandomIsAlphanumericOfRequestedLength() {
    let random = FilenameTemplate.randomAlphanumeric(12)
    #expect(random.count == 12)
    #expect(random.allSatisfy { $0.isLetter || $0.isNumber })
}

@Test
func validationRejectsEmptyResults() {
    #expect(!FilenameTemplate.isValid(""))
    #expect(!FilenameTemplate.isValid(".png"))      // bare extension is not a name
    #expect(FilenameTemplate.isValid("%window"))
    #expect(FilenameTemplate.isValid("Screenshot_%y-%mo-%d_%h-%mi-%s.png"))
    #expect(FilenameTemplate.isValid("%mode/%y"))
}

@Test
func extensionSuffixDetection() {
    #expect(FilenameTemplate.extensionSuffix(of: "shot.png") == ".png")
    #expect(FilenameTemplate.extensionSuffix(of: "shot.PNG") == ".PNG")
    #expect(FilenameTemplate.extensionSuffix(of: "shot.heic") == ".heic")
    #expect(FilenameTemplate.extensionSuffix(of: "shot") == "")
    #expect(FilenameTemplate.extensionSuffix(of: "shotpng") == "")
}
