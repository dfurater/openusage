import XCTest
@testable import OpenUsage

/// The Cowork sandbox identity walk: each session's `.claude` dir names its account (or doesn't).
/// Routing is the assembly's job — see `ProviderAccountAssemblyTests`.
final class ClaudeCoworkDiscoveryTests: XCTestCase {
    private let sandboxA = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/g/s/local_1/.claude")
    private let sandboxB = URL(fileURLWithPath: "/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/g/s/local_2/.claude")

    private func makeDiscovery(files: [String: String], sandboxes: [URL]) -> ClaudeCoworkDiscovery {
        ClaudeCoworkDiscovery(
            files: FakeFiles(files),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in sandboxes }
        )
    }

    func testReadsIdentityLabelAndOrganizationPerSandbox() throws {
        let discovery = makeDiscovery(
            files: [
                sandboxA.path + "/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationUuid": "ORG-2", "organizationName": "Sunstory"}}"#,
            ],
            sandboxes: [sandboxA]
        )

        let result = discovery.run()

        let sandbox = try XCTUnwrap(result.sandboxes.first)
        XCTAssertEqual(result.sandboxes.count, 1)
        XCTAssertEqual(sandbox.root, sandboxA)
        XCTAssertEqual(sandbox.identityKey, "acct-2|org-2")
        XCTAssertEqual(sandbox.label, "work@example.com (Sunstory)")
        XCTAssertEqual(sandbox.organization, "org-2")
    }

    func testASandboxWithoutAnIdentityFileStillReportsItsRoot() {
        // No identity = the sandbox stays on the default card; the root must still be reported so
        // the assembly can keep it in the default card's partition.
        let discovery = makeDiscovery(files: [:], sandboxes: [sandboxA, sandboxB])

        let result = discovery.run()

        XCTAssertEqual(result.sandboxes.map(\.root), [sandboxA, sandboxB])
        XCTAssertEqual(result.sandboxes.compactMap(\.identityKey), [])
    }

    func testHittingTheTimeBudgetFlagsTheResultTruncated() {
        let roots = [sandboxA, sandboxB]
        let discovery = ClaudeCoworkDiscovery(
            files: FakeFiles([:]),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSandboxes: { _ in roots },
            timeBudget: -1
        )

        let result = discovery.run()

        XCTAssertTrue(result.truncated, "the assembly needs to know the list is not the whole truth")
        XCTAssertTrue(result.sandboxes.isEmpty)
        XCTAssertEqual(result.notes.count, 1)
    }

    func testDiscoversHundredsOfCoworkSandboxesWithoutTruncating() {
        let roots = (0..<250).map { index in
            URL(fileURLWithPath:
                "/Users/dev/Library/Application Support/Claude/local-agent-mode-sessions/g/s/local_\(index)/.claude"
            )
        }
        let files = Dictionary(uniqueKeysWithValues: roots.enumerated().map { index, root in
            (
                root.path + "/.claude.json",
                #"{"oauthAccount":{"accountUuid":"ACCOUNT-\#(index % 3)","organizationUuid":"ORG-\#(index % 3)"}}"#
            )
        })
        let discovery = makeDiscovery(files: files, sandboxes: roots)

        let result = discovery.run()

        XCTAssertFalse(result.truncated)
        XCTAssertEqual(result.sandboxes.count, roots.count)
        XCTAssertEqual(
            Set(result.sandboxes.compactMap(\.identityKey)),
            ["account-0|org-0", "account-1|org-1", "account-2|org-2"]
        )
    }

    func testAnIdentityFileNamingNoAccountCountsAsUnidentified() {
        let discovery = makeDiscovery(
            files: [sandboxA.path + "/.claude.json": #"{"oauthAccount": {}}"#],
            sandboxes: [sandboxA]
        )

        let result = discovery.run()

        XCTAssertEqual(result.sandboxes.first?.identityKey, nil)
    }
}
