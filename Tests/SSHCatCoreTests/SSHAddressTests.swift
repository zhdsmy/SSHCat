import Foundation
import Testing
@testable import SSHCatCore

@Suite struct SSHAddressTests {
    @Test func acceptsIPv6DestinationsAndScopes() throws {
        for host in ["2001:db8::1", "[2001:db8::1]", "fe80::1%en0", "[fe80::1%en0]"] {
            var rule = sampleRule()
            rule.host = host
            try rule.validate()
        }

        var bracketed = sampleRule()
        bracketed.host = "[2001:db8::1]"
        #expect(bracketed.destination == "app@2001:db8::1")
        #expect(try bracketed.arguments().last == "app@2001:db8::1")
    }

    @Test func bracketsIPv6ForwardArgumentsAndEndpoints() throws {
        let forward = PortForward(
            kind: .local,
            bindAddress: "[fe80::1%en0]",
            bindPort: 8080,
            targetHost: "2001:db8::2",
            targetPort: 9000
        )
        #expect(try forward.arguments() == ["-L", "[fe80::1%en0]:8080:[2001:db8::2]:9000"])
        #expect(forward.localEndpoint == "[fe80::1%en0]:8080")
        #expect(forward.summary.contains("[fe80::1%en0]:8080"))
        #expect(forward.summary.contains("[2001:db8::2]:9000"))

        let dynamic = PortForward(kind: .dynamic, bindAddress: "::1", bindPort: 1080)
        #expect(try dynamic.arguments() == ["-D", "[::1]:1080"])
        #expect(dynamic.localEndpoint == "[::1]:1080")

        let remote = PortForward(kind: .remote, bindAddress: "::", bindPort: 9000,
                                 targetHost: "[2001:db8::2]", targetPort: 3000)
        #expect(remote.summary.contains("[::]:9000"))
        #expect(remote.summary.contains("[2001:db8::2]:3000"))
    }

    @Test func rejectsPortConfusionAndInjection() {
        for host in ["-oProxyCommand=oops", "app@devbox", "devbox:22", "[2001:db8::1]:22",
                     "2001:db8::zz", "dev\nbox", "devbox\n", "dev\0box", "[::1]\0suffix",
                     "[not-ipv6]"] {
            #expect(!SSHToken.isHost(host))
        }

        for address in ["127.0.0.1:8080", "[::1]:8080", "[2001:db8::zz]", "fe80::1%",
                        "fe80::1%en 0", "fe80::1%-en0", "-L", "app@host", "::1\n-L",
                        "127.0.0.1\r", "::1\0suffix", "[::1]\0suffix", "[not-ipv6]"] {
            #expect(!SSHToken.isAddress(address))
        }

        var rule = sampleRule()
        rule.host = "devbox:22"
        #expect(throws: ForwardIssue.invalidHost) { try rule.validate() }
        rule = sampleRule()
        rule.forwards[0].bindAddress = "127.0.0.1:8080"
        #expect(throws: ForwardIssue.self) { try rule.validate() }
        rule = sampleRule()
        rule.forwards[0].targetHost = "[::1]:8080"
        #expect(throws: ForwardIssue.self) { try rule.validate() }
    }

    @Test func gatewayPortsRecognizesBothLoopbackFamilies() {
        for address in ["localhost", "127.0.0.1", "127.23.4.5", "::1", "[::1]"] {
            #expect(!remoteForward(address).needsGatewayPorts)
        }
        for address in ["0.0.0.0", "::", "*", "192.0.2.5", "2001:db8::5"] {
            #expect(remoteForward(address).needsGatewayPorts)
        }
    }

    @Test func listenerConflictsRespectAddressFamiliesAndWildcards() {
        #expect(forward("localhost").clashes(with: forward("127.0.0.1")))
        #expect(forward("localhost").clashes(with: forward("::1")))
        #expect(forward("127.0.0.1").clashes(with: forward("127.0.0.2")) == false)
        #expect(!forward("127.0.0.1").clashes(with: forward("::1")))
        #expect(!forward("2001:db8::1").clashes(with: forward("192.0.2.1")))
        #expect(forward("2001:db8::1").clashes(with: forward("2001:0db8:0:0:0:0:0:1")))
        #expect(forward("fe80::1").clashes(with: forward("fe80::1%en0")))
        #expect(!forward("fe80::1%en0").clashes(with: forward("fe80::1%en1")))

        #expect(forward("0.0.0.0").clashes(with: forward("192.0.2.1")))
        #expect(forward("::").clashes(with: forward("2001:db8::1")))
        #expect(!forward("0.0.0.0").clashes(with: forward("2001:db8::1")))
        #expect(!forward("::").clashes(with: forward("192.0.2.1")))
        #expect(forward("*").clashes(with: forward("2001:db8::1")))
        #expect(!forward("::1", port: 8080).clashes(with: forward("::1", port: 8081)))
        #expect(!remoteForward("::1").clashes(with: forward("::1")))
    }

    @Test func localhostConflictsOnlyWithItsListenersAndWildcards() {
        let localhost = forward("localhost")
        for address in ["127.0.0.1", "::1", "[0:0:0:0:0:0:0:1]", "0.0.0.0", "::", "*", "localhost"] {
            #expect(localhost.clashes(with: forward(address)))
            #expect(forward(address).clashes(with: localhost))
        }
        for address in ["127.0.0.2", "127.23.4.5", "192.0.2.1", "2001:db8::1"] {
            #expect(!localhost.clashes(with: forward(address)))
            #expect(!forward(address).clashes(with: localhost))
        }
        #expect(!remoteForward("127.0.0.2").needsGatewayPorts)
    }

    @Test func decodesLegacyForwardData() throws {
        let json = #"{"name":"legacy","host":"devbox","forwards":[{"kind":"local","bindAddress":"127.0.0.1","bindPort":8080,"targetHost":"127.0.0.1","targetPort":8080}]}"#
        let rule = try JSONDecoder().decode(ForwardRule.self, from: Data(json.utf8))
        #expect(rule.name == "legacy")
        #expect(rule.autoRestart)
        #expect(!rule.autoStart)
        #expect(try rule.arguments().contains("127.0.0.1:8080:127.0.0.1:8080"))
    }
}

private func sampleRule() -> ForwardRule {
    ForwardRule(name: "test", user: "app", host: "devbox", forwards: [PortForward()])
}

private func forward(_ address: String, port: Int = 8080) -> PortForward {
    PortForward(kind: .local, bindAddress: address, bindPort: port)
}

private func remoteForward(_ address: String) -> PortForward {
    PortForward(kind: .remote, bindAddress: address, bindPort: 8080)
}
