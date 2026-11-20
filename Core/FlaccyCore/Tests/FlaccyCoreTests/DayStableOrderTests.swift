import XCTest
@testable import FlaccyCore

final class DayStableOrderTests: XCTestCase {

    private let candidates: [(name: String, weight: Double)] = [
        ("alpha", 1), ("beta", 3), ("gamma", 2), ("delta", 5), ("epsilon", 0.5),
    ]

    private func order(on day: Int64) -> [String] {
        DayStableOrder.ordered(candidates, day: day, name: \.name, weight: \.weight).map(\.name)
    }

    func testD1TheListeningDayTurnsOverAtFiveInTheMorningLocalTime() {
        let lateEvening = Date(timeIntervalSince1970: 1_795_217_400)
        XCTAssertEqual(DayStableOrder.day(of: lateEvening, secondsFromGMT: 0), 20_777)
        XCTAssertEqual(DayStableOrder.day(of: lateEvening, secondsFromGMT: 7_200), 20_777)
        XCTAssertEqual(DayStableOrder.day(of: lateEvening, secondsFromGMT: -28_800), 20_777)
        let beforeFive = Date(timeIntervalSince1970: 1_795_233_540)
        XCTAssertEqual(DayStableOrder.day(of: beforeFive, secondsFromGMT: 0), 20_777)
        XCTAssertEqual(DayStableOrder.day(of: beforeFive, secondsFromGMT: 3_600), 20_777)
        XCTAssertEqual(DayStableOrder.day(of: Date(timeIntervalSince1970: 1_795_237_199), secondsFromGMT: 0), 20_777)
        XCTAssertEqual(DayStableOrder.day(of: Date(timeIntervalSince1970: 1_795_237_200), secondsFromGMT: 0), 20_778)
    }

    func testD2DrawsMatchTheSharedVectors() {
        XCTAssertEqual(DayStableOrder.draw(day: 20_412, name: "kind of blue\u{0}miles davis"), 0.20503830680303542)
        XCTAssertEqual(DayStableOrder.draw(day: 20_413, name: "kind of blue\u{0}miles davis"), 0.8589927958451198)
    }

    func testD3TheOrderMatchesTheSharedVectorsAndMovesWithTheDay() {
        XCTAssertEqual(order(on: 20_412), ["gamma", "delta", "beta", "epsilon", "alpha"])
        XCTAssertEqual(order(on: 20_413), ["beta", "delta", "alpha", "gamma", "epsilon"])
        XCTAssertEqual(order(on: 20_414), ["beta", "alpha", "gamma", "delta", "epsilon"])
    }

    func testD4RebuildingTheSameDayGivesTheSameOrderWhateverOrderTheCandidatesArrive() {
        let reversed = DayStableOrder.ordered(Array(candidates.reversed()), day: 20_412, name: \.name, weight: \.weight)
        XCTAssertEqual(reversed.map(\.name), order(on: 20_412))
        XCTAssertEqual(order(on: 20_412), order(on: 20_412))
    }

    func testD5HeavierCandidatesLeadAboutAsOftenAsTheirWeightSays() {
        let pair: [(name: String, weight: Double)] = [("light", 1), ("heavy", 10)]
        let heavyLeads = (20_000..<21_000).filter { day in
            DayStableOrder.ordered(pair, day: Int64(day), name: \.name, weight: \.weight).first?.name == "heavy"
        }.count
        XCTAssertEqual(heavyLeads, 909)
    }

    func testD6EqualNamesKeepTheOrderTheyCameIn() {
        let twins: [(name: String, weight: Double, tag: Int)] = [("same", 1, 1), ("same", 1, 2)]
        XCTAssertEqual(DayStableOrder.ordered(twins, day: 1, name: \.name, weight: \.weight).map(\.tag), [1, 2])
    }
}
