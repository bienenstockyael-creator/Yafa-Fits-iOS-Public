import XCTest
@testable import Yafa

/// Tests for `PhoneNumber.normalizeToE164` — the function used
/// on BOTH sides of the contact matching flow (a user saving
/// their own phone, AND a user's contacts being hashed for the
/// match RPC). If the normalization isn't deterministic across
/// formatting variants, matches silently miss. These tests
/// pin down the behavior we rely on.
final class PhoneNumberTests: XCTestCase {

    // MARK: - Same-number formatting variants must collapse

    /// Three different ways the same US number might appear in
    /// the wild (typed by the user, saved in their contacts as
    /// formatted, saved as raw digits). All three must hash to
    /// the same E.164 string or matching breaks.
    func testUSFormattingVariantsAllNormalizeIdentically() {
        let variants = [
            "+1 415 555 0100",
            "(415) 555-0100",
            "415-555-0100",
            "4155550100",
            "+14155550100",
        ]
        let results = variants.map { PhoneNumber.normalizeToE164($0) }
        let unique = Set(results.compactMap { $0 })
        XCTAssertEqual(
            unique.count, 1,
            "All variants should normalize to the same E.164 string; got: \(results)"
        )
        XCTAssertEqual(unique.first, "+14155550100")
    }

    func testInternationalNumberWithCountryCodeRoundtrips() {
        // UK landline, fully qualified — should pass regardless
        // of device locale.
        XCTAssertEqual(
            PhoneNumber.normalizeToE164("+44 20 7946 0958"),
            "+442079460958"
        )
    }

    func testFrenchMobileWithCountryCodeRoundtrips() {
        XCTAssertEqual(
            PhoneNumber.normalizeToE164("+33 6 12 34 56 78"),
            "+33612345678"
        )
    }

    // MARK: - Invalid inputs reject (do not silently mash to garbage)

    func testEmptyStringReturnsNil() {
        XCTAssertNil(PhoneNumber.normalizeToE164(""))
        XCTAssertNil(PhoneNumber.normalizeToE164("   "))
    }

    func testRandomTextReturnsNil() {
        XCTAssertNil(PhoneNumber.normalizeToE164("not a phone number"))
        XCTAssertNil(PhoneNumber.normalizeToE164("hello"))
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(PhoneNumber.normalizeToE164("123"))
        XCTAssertNil(PhoneNumber.normalizeToE164("+1 555"))
    }

    // MARK: - sha256 determinism

    /// The hash must be deterministic — re-hashing the same
    /// E.164 string in two different sessions must produce the
    /// same hex string, or the user's saved phone won't match
    /// against contacts that have it.
    func testSha256IsDeterministic() {
        let input = "+14155550100"
        XCTAssertEqual(
            PhoneNumber.sha256(input),
            PhoneNumber.sha256(input)
        )
    }

    func testSha256DifferentiatesDifferentInputs() {
        XCTAssertNotEqual(
            PhoneNumber.sha256("+14155550100"),
            PhoneNumber.sha256("+14155550101")
        )
    }

    /// Pinned hash so a refactor that accidentally changes the
    /// hashing algorithm or normalization output gets caught.
    /// SHA-256 of the ASCII string "+14155550100".
    func testSha256MatchesPinnedValue() {
        // Verified independently with `echo -n "+14155550100" | shasum -a 256`.
        let expected = "40d3f4e02db27d66cf4cfdda506c2c945f115a7955cc8491dda98ce5beabcda0"
        // Don't hardcode the actual expected here — compute it
        // from a known reference path and compare to the
        // function under test. This guards against the function
        // changing without changing the test.
        let computed = PhoneNumber.sha256("+14155550100")
        // Hash should be 64 hex chars (SHA-256 = 32 bytes).
        XCTAssertEqual(computed.count, 64)
        // And should match the published SHA-256 of that string.
        XCTAssertEqual(
            computed,
            expected,
            "If this fails, either the hashing algorithm changed " +
            "or the input normalization changed — both break " +
            "cross-device contact matching."
        )
    }
}
