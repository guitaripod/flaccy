import XCTest
@testable import FlaccyCore

final class DeadlineTests: XCTestCase {

    func testValueArrivesBeforeTheLimit() async {
        let value = await Deadline.value(within: .seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testCancellableWorkPastTheLimitYieldsNil() async {
        let began = ContinuousClock.now
        let value = await Deadline.value(within: .milliseconds(100)) { () -> Int in
            try? await Task.sleep(for: .seconds(10))
            return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
    }

    func testWorkThatIgnoresCancellationDoesNotHoldTheCaller() async {
        let began = ContinuousClock.now
        let value = await Deadline.value(within: .milliseconds(100)) { () -> Int in
            usleep(3_000_000)
            return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2))
    }

    func testCancelledWorkStillReportsTheTimeout() async {
        let cancelled = expectation(description: "the read is told to stop")
        let value = await Deadline.value(within: .milliseconds(50)) { () -> Int in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            cancelled.fulfill()
            return 1
        }
        XCTAssertNil(value)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testManyQuickReadsAllArrive() async {
        let values = await withTaskGroup(of: Int?.self) { group in
            for index in 0..<500 {
                group.addTask { await Deadline.value(within: .seconds(5)) { index } }
            }
            var collected: [Int] = []
            for await value in group { collected.append(value ?? -1) }
            return collected
        }
        XCTAssertEqual(values.sorted(), Array(0..<500))
    }
}
