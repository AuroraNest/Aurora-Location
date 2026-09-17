import Foundation
import NetworkExtension

@main
struct PersonalVPNCheck {
    @MainActor static func main() {
        let valid = PersonalVPNConfiguration(
            serverAddress: "vpn.example.com", remoteIdentifier: "vpn.example.com", username: "aurora"
        )
        assert(valid.validationError() == nil)
        assert(PersonalVPNConfiguration.isBareHostOrIP("192.0.2.1"))
        assert(PersonalVPNConfiguration.isBareHostOrIP("2001:db8::1"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("https://vpn.example.com"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("vpn.example.com:500"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("vpn.example.com/path"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("user@vpn.example.com"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("vpn.example.com\n"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("-vpn.example.com"))
        assert(!PersonalVPNConfiguration.isBareHostOrIP("vpn..example.com"))
        var missingIdentity = valid
        missingIdentity.remoteIdentifier = ""
        assert(missingIdentity.validationError() == .invalidRemoteIdentifier)
        var missingUser = valid
        missingUser.username = " \n"
        assert(missingUser.validationError() == .missingUsername)
        assert(PersonalVPN.isUnconfigured(protocolConfiguration: nil, isEnabled: false, status: .invalid))
        assert(!PersonalVPN.isUnconfigured(protocolConfiguration: NEVPNProtocolIKEv2(), isEnabled: false, status: .invalid))
        assert(!PersonalVPN.isUnconfigured(protocolConfiguration: nil, isEnabled: true, status: .invalid))
        assert(!PersonalVPN.isUnconfigured(protocolConfiguration: nil, isEnabled: false, status: .connected))
        let failure = NSError(domain: NEVPNConnectionErrorDomain, code: 15,
                              userInfo: [NSLocalizedDescriptionKey: "private-peer-secret"])
        assert(PersonalVPN.disconnectDescription(failure).contains("VPN 15"))
        assert(!PersonalVPN.disconnectDescription(failure).contains("private-peer-secret"))
        assert(PersonalVPN.disconnectDescription(nil) == "系统未提供最近断开原因.")
        assert(!PersonalVPN.disconnectDescription(NSError(domain: "private-domain", code: 1)).contains("private-domain"))
        print("PASS: Personal VPN validates addresses and identities, and recognizes the fresh iOS manager state")
    }
}
