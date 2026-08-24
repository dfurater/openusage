import XCTest
@testable import OpenUsage

@MainActor
final class AccountDiscoveryThreadingTests: XCTestCase {
    func testAccountFilesystemScansRunOffTheMainThread() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: {
                ClaudeConfigDirDiscovery.Result(notes: [Thread.isMainThread ? "main" : "background"])
            },
            coworkScan: {
                ClaudeCoworkDiscovery.Result(notes: [Thread.isMainThread ? "main" : "background"])
            }
        )

        XCTAssertEqual(prepared.config.notes, ["background"])
        XCTAssertEqual(prepared.cowork.notes, ["background"])
    }

    func testCancelledCoworkScanQuarantinesItsPartialResult() async {
        let sandbox = URL(fileURLWithPath: "/Users/dev/cowork/.claude")
        let result = await Task.detached {
            ClaudeCoworkDiscovery(
                files: FakeFiles([:]),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
                listSandboxes: { _ in
                    withUnsafeCurrentTask { task in task?.cancel() }
                    return [sandbox]
                }
            ).run()
        }.value

        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.sandboxes.isEmpty)
        XCTAssertEqual(result.notes, ["cowork sandbox scan cancelled → skipping incomplete cowork routing"])
    }

    func testCancellationAfterConfigScanSkipsCoworkDiscovery() async {
        let prepared = await AppContainer.prepareAccountDiscovery(
            configScan: {
                withUnsafeCurrentTask { task in task?.cancel() }
                return ClaudeConfigDirDiscovery.Result(notes: ["config scanned"])
            },
            coworkScan: {
                ClaudeCoworkDiscovery.Result(notes: ["cowork should not run"])
            }
        )

        XCTAssertEqual(prepared.config.notes, ["config scanned"])
        XCTAssertTrue(prepared.cowork.truncated)
        XCTAssertTrue(prepared.cowork.notes.isEmpty)
    }
}
