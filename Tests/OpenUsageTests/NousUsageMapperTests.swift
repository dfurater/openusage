import XCTest
@testable import OpenUsage

final class NousUsageMapperTests: XCTestCase {
    // MARK: - /api/billing/state

    func testMonthlyCapMapsSpentAgainstLimit() throws {
        let data = try XCTUnwrap(ProviderParse.jsonObject(Data(#"""
        {"monthlyCap": {"limitUsd": "1000", "spentThisMonthUsd": "123.45"}}
        """#.utf8)))

        guard case .progress(let label, let used, let limit, .dollars, let resetsAt, _, _)? =
                NousUsageMapper.monthlyCapLine(from: data).first else {
            return XCTFail("expected a dollar progress line")
        }
        XCTAssertEqual(label, "Monthly Cap")
        XCTAssertEqual(used, 123.45, accuracy: 0.001)
        XCTAssertEqual(limit, 1000, accuracy: 0.001)
        XCTAssertNil(resetsAt)
    }

    func testMonthlyCapSkippedWhenLimitIsZeroOrMissing() {
        let zero = ["monthlyCap": ["limitUsd": "0", "spentThisMonthUsd": "5"]]
        XCTAssertTrue(NousUsageMapper.monthlyCapLine(from: zero).isEmpty)

        let missing = ["balanceUsd": "1.00"]
        XCTAssertTrue(NousUsageMapper.monthlyCapLine(from: missing).isEmpty)
    }

    func testBalanceShowsMeasuredZero() throws {
        // A real zero is a measured zero ("$0.00 left"), never "No data" — OpenRouter convention.
        let data = try XCTUnwrap(ProviderParse.jsonObject(Data(#"{"balanceUsd": "0"}"#.utf8)))

        guard case .values(_, let values, _, _, _, _)? = NousUsageMapper.balanceLine(from: data).first,
              let balance = values.first?.number else {
            return XCTFail("expected a values line with a number")
        }
        XCTAssertEqual(balance, 0)
        XCTAssertEqual(values.first?.kind, .dollars)
    }

    // MARK: - /api/billing/subscription

    func testCreditsMeterUsesRemainingAgainstMonthlyWithCycleReset() throws {
        let data = try XCTUnwrap(ProviderParse.jsonObject(Data(#"""
        {"current": {"tierName": "Plus", "monthlyCredits": "22",
                     "creditsRemaining": "11.5", "cycleEndsAt": "2099-09-04T10:09:32Z"}}
        """#.utf8)))

        let (plan, lines) = NousUsageMapper.subscriptionMetrics(from: data)

        XCTAssertEqual(plan, "Plus")
        guard case .progress(let label, let used, let limit, .dollars, let resetsAt, _, _)? = lines.first else {
            return XCTFail("expected the credits meter first")
        }
        XCTAssertEqual(label, "Credits")
        XCTAssertEqual(used, 10.5, accuracy: 0.001)
        XCTAssertEqual(limit, 22, accuracy: 0.001)
        XCTAssertNotNil(resetsAt)

        // The raw remaining row follows so even a fully-used cycle keeps a number on screen.
        guard case .values(_, let remaining, _, _, _, _)? = lines.last,
              let left = remaining.first?.number else {
            return XCTFail("expected the credits-left row with a number")
        }
        XCTAssertEqual(left, 11.5, accuracy: 0.001)
        XCTAssertEqual(remaining.first?.label, "left")
    }

    func testZeroCreditTierSkipsMeterButKeepsRemainingRow() throws {
        // A tier without a monthly allotment has no meaningful ceiling — but the real remaining
        // amount must still render instead of vanishing into "No data".
        let data = try XCTUnwrap(ProviderParse.jsonObject(Data(#"""
        {"current": {"tierName": "Free", "monthlyCredits": "0", "creditsRemaining": "0.1"}}
        """#.utf8)))

        let (_, lines) = NousUsageMapper.subscriptionMetrics(from: data)
        XCTAssertEqual(lines.count, 1)
        guard case .values(let label, let values, _, _, _, _) = lines[0],
              let remaining = values.first?.number else {
            return XCTFail("expected a values row with a number")
        }
        XCTAssertEqual(label, "Credits Left")
        XCTAssertEqual(remaining, 0.1, accuracy: 0.001)
    }

    func testPlanNameComesFromCurrentTier() throws {
        let data = try XCTUnwrap(ProviderParse.jsonObject(Data(#"{"current": {"tierName": "Ultra"}}"#.utf8)))
        XCTAssertEqual(NousUsageMapper.planName(from: data), "Ultra")
    }
}
