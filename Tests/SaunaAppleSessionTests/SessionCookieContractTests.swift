import Foundation
import Testing
@testable import SaunaAppleSession

@Suite struct SessionCookieContractTests {
    let url = URL(string: "http://127.0.0.1:8080/auth/passkeys/authentication/finish")!
    func header(profile: String = "customer", token: String? = nil, age: Int = 3600) -> String {
        "__Host-sauna-\(profile)-session=\(token ?? fixtureToken().encoded); Path=/; Max-Age=\(age); Secure; HttpOnly; SameSite=Strict"
    }
    @Test func onlyTheExpectedProfileAndLocalEndpointCanIssueASession() throws {
        let update = try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: url, statusCode: 200,
            setCookieValues: [header()], metadataExpiresAt: now.addingTimeInterval(7200), now: now)
        guard case .issued(_, let expires) = update else { Issue.record("Expected issue result"); return }
        #expect(expires == now.addingTimeInterval(3600))
        #expect(Mirror(reflecting: update).children.isEmpty)
        for target in ["http://elsewhere.invalid:8080/auth/passkeys/authentication/finish", "http://127.0.0.1:8080/auth/session", "http://127.0.0.1:8080/auth/passkeys/authentication/finish?q=1"] {
            #expect(throws: SessionContractError.invalidValue) {
                try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: URL(string: target)!, statusCode: 200,
                    setCookieValues: [header()], metadataExpiresAt: now.addingTimeInterval(60), now: now)
            }
        }
        #expect(throws: SessionContractError.invalidValue) {
            try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: url, statusCode: 200,
                setCookieValues: [header(profile: "staff")], metadataExpiresAt: now.addingTimeInterval(60), now: now)
        }
    }
    @Test func malformedFoldedDuplicateAndWeakenedCookiesAreRejected() {
        let valid = header()
        for values in [[], [valid, valid], [valid + ", " + valid], [valid + "; Domain=localhost"],
                       [valid.replacing("; Secure", with: "")], [valid.replacing("; HttpOnly", with: "")],
                       [valid.replacing("SameSite=Strict", with: "SameSite=Lax")], [valid.replacing("Path=/", with: "Path=/auth")],
                       [valid.replacing("Secure", with: "Secure=false")], [header(token: "bad")], [header(age: -1)]] {
            #expect(throws: SessionContractError.invalidValue) {
                try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: url, statusCode: 200,
                    setCookieValues: values, metadataExpiresAt: now.addingTimeInterval(60), now: now)
            }
        }
    }
    @Test func onlySuccessfulLogoutOrCredentialChangesCanClearTheCookie() throws {
        let deletion = header(token: "", age: 0)
        let logout = URL(string: "http://127.0.0.1:8080/auth/logout")!
        let value = try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: logout, statusCode: 204, setCookieValues: [deletion], now: now)
        guard case .cleared = value else { Issue.record("Expected clear result"); return }
        for status in [200, 302, 400, 401, 500] {
            #expect(throws: SessionContractError.invalidValue) {
                try SessionCookieContract.acceptLocalResponse(scope: localCustomer, url: logout, statusCode: status, setCookieValues: [deletion], now: now)
            }
        }
    }
}
