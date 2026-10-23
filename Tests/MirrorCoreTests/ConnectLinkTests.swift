import XCTest
@testable import MirrorCore

final class ConnectLinkTests: XCTestCase {
    func testRoundTripKeepsNamePortAndHostOrder() {
        let link = ConnectLink(name: "Mirror Wall 2 · MacBook Pro", port: 7450, hosts: ["192.168.1.20", "100.101.102.103"])
        XCTAssertEqual(link.text, "mirrorwall://connect?name=Mirror%20Wall%202%20%C2%B7%20MacBook%20Pro&port=7450&host=192.168.1.20&host=100.101.102.103")
        XCTAssertEqual(ConnectLink(text: link.text), link)
    }

    /// The link the first app and Mirror Wall with QR codes agree on; a change here breaks phones in the field.
    func testFirstLinkFormStillParses() {
        let link = ConnectLink(text: "mirrorwall://connect?name=Mirror%20Wall%201&port=7350&host=10.0.0.5")
        XCTAssertEqual(link, ConnectLink(name: "Mirror Wall 1", port: 7350, hosts: ["10.0.0.5"]))
    }

    func testMissingPortMeansSlotOneAndUnknownItemsAreIgnored() {
        let link = ConnectLink(text: " MIRRORWALL://connect?host=10.0.0.5&future=1 \n")
        XCTAssertEqual(link?.port, 7350)
        XCTAssertEqual(link?.name, "10.0.0.5")
        XCTAssertEqual(link?.hosts, ["10.0.0.5"])
    }

    func testRejectsOtherLinksAndBadPorts() {
        XCTAssertNil(ConnectLink(text: "https://example.com/?host=1.2.3.4"))
        XCTAssertNil(ConnectLink(text: "mirrorwall://other?host=1.2.3.4"))
        XCTAssertNil(ConnectLink(text: "mirrorwall://connect?name=x&port=7350"))
        XCTAssertNil(ConnectLink(text: "mirrorwall://connect?host=1.2.3.4&port=abc"))
        XCTAssertNil(ConnectLink(text: "mirrorwall://connect?host=1.2.3.4&port=70000"))
    }

    func testDuplicateHostsCollapse() {
        let link = ConnectLink(text: "mirrorwall://connect?host=10.0.0.5&host=10.0.0.5&host=10.0.0.6")
        XCTAssertEqual(link?.hosts, ["10.0.0.5", "10.0.0.6"])
    }
}
