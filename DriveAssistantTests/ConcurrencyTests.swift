import XCTest
@testable import DriveAssistant

final class ConcurrencyTests: XCTestCase {
    func testDiagnosticsLogStoreConcurrentWritesAndClear() {
        let store = DiagnosticsLogStore()
        let expectation = expectation(description: "Concurrent tasks")
        expectation.expectedFulfillmentCount = 2

        DispatchQueue.global().async {
            for i in 0..<100 {
                store.record(type: "test_\(i)")
            }
            expectation.fulfill()
        }

        DispatchQueue.global().async {
            store.clear()
            expectation.fulfill()
        }

        waitForExpectations(timeout: 5.0)
    }
}
