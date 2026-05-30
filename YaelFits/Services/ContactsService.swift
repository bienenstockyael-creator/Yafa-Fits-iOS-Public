import Contacts
import CryptoKit
import Foundation
import PhoneNumberKit

/// Permission + fetch + match helpers for the "Find your people"
/// contacts flow. The flow:
///   1. User taps the popup's primary action
///   2. We request system Contacts access (iOS shows the native
///      alert, text driven by NSContactsUsageDescription in
///      Info.plist)
///   3. On grant, we read all contacts (name + phone + email)
///   4. We call the backend to find which contacts are already
///      Yafa users, and return their Profiles for the hero to
///      repopulate its floating avatar bubbles
enum ContactsService {

    enum AccessResult {
        case granted
        case denied
        case restricted
    }

    /// One contact pulled off the device. We extract only what we
    /// need for matching — display name (for fallback UI) and the
    /// raw phone/email lists.
    struct DeviceContact {
        let displayName: String
        let phoneNumbers: [String]
        let emails: [String]
    }

    static func requestAccess() async -> AccessResult {
        let store = CNContactStore()
        let currentStatus = CNContactStore.authorizationStatus(for: .contacts)

        // Already-granted / already-denied short-circuits so we
        // don't re-prompt and don't trigger the system alert when
        // we already know the answer.
        switch currentStatus {
        case .authorized, .limited:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            break
        @unknown default:
            return .denied
        }

        do {
            let granted = try await store.requestAccess(for: .contacts)
            return granted ? .granted : .denied
        } catch {
            return .denied
        }
    }

    /// Reads all contacts off the device. Caller is responsible
    /// for confirming `requestAccess()` returned `.granted`
    /// before invoking — calling without authorization throws.
    static func fetchAllContacts() async throws -> [DeviceContact] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        return try await Task.detached(priority: .userInitiated) {
            var results: [DeviceContact] = []
            try store.enumerateContacts(with: request) { contact, _ in
                let name = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let phones = contact.phoneNumbers.map { $0.value.stringValue }
                let emails = contact.emailAddresses.map { $0.value as String }
                guard !phones.isEmpty || !emails.isEmpty else { return }
                results.append(DeviceContact(
                    displayName: name.isEmpty ? "?" : name,
                    phoneNumbers: phones,
                    emails: emails
                ))
            }
            return results
        }.value
    }

    /// Match device contacts against existing Yafa users.
    ///
    /// Phone numbers are normalized to E.164 (using the device's
    /// region as the default country code for unprefixed numbers)
    /// and hashed with SHA-256 client-side, so we never send raw
    /// numbers to the server. The matching RPC compares hashes
    /// and returns only matching profiles.
    static func findMatchingProfiles(
        from contacts: [DeviceContact]
    ) async throws -> [Profile] {
        let hashes = contacts
            .flatMap { $0.phoneNumbers }
            .compactMap { PhoneNumber.normalizeToE164($0) }
            .map { PhoneNumber.sha256($0) }

        guard !hashes.isEmpty else { return [] }

        // Dedupe before the network round-trip — contact lists
        // often have the same number under multiple entries
        // (work + mobile, etc).
        let uniqueHashes = Array(Set(hashes))

        struct MatchParams: Encodable { let hashes: [String] }
        let profiles: [Profile] = try await supabase
            .rpc("match_contacts_by_phone", params: MatchParams(hashes: uniqueHashes))
            .execute()
            .value
        return profiles
    }

    /// Hash a phone number for storing on the user's own profile.
    /// Returns nil if the input can't be normalized to E.164.
    static func hashOwnPhoneNumber(_ raw: String) -> String? {
        guard let e164 = PhoneNumber.normalizeToE164(raw) else { return nil }
        return PhoneNumber.sha256(e164)
    }
}

// MARK: - Phone number normalization

/// Phone normalization helpers. We need every phone — both the
/// user's own input AND every contact phone — to land at the
/// exact same string before hashing, otherwise hashes won't
/// match even though the underlying number is the same.
///
/// Backed by PhoneNumberKit (Swift port of Google's
/// libphonenumber): handles every country's formatting rules,
/// detects country codes from the device locale, and rejects
/// numbers that don't pass that country's validation. Replaces
/// the previous naïve implementation that only worked for
/// numbers explicitly prefixed with `+` and a hand-rolled
/// country-code table.
enum PhoneNumber {
    /// Shared PhoneNumberUtility. The first instantiation loads
    /// the country metadata bundle (~tens of KB), so we hold a
    /// single shared instance for the app lifetime instead of
    /// paying that cost per call.
    private static let utility = PhoneNumberUtility()

    /// Convert an arbitrarily-formatted phone string to E.164
    /// (e.g. `+12125551234`). Returns nil for input that fails
    /// PhoneNumberKit validation (too short for the region,
    /// invalid digits, etc.).
    ///
    /// Numbers without a country code use the device's region
    /// from `Locale.current` — so a US user typing "212 555
    /// 1234" produces "+12125551234", and a UK user typing the
    /// same digits would (correctly) be rejected as invalid for
    /// that region.
    static func normalizeToE164(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let region = defaultRegion()
        guard let parsed = try? utility.parse(
            trimmed,
            withRegion: region,
            ignoreType: true
        ) else {
            return nil
        }
        return utility.format(parsed, toType: .e164)
    }

    static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// ISO region identifier (e.g. "US", "GB") for default-
    /// parsing numbers that don't include an explicit country
    /// code. Falls back to "US" for anonymous/unset locales so
    /// we never produce a nil region.
    private static func defaultRegion() -> String {
        if #available(iOS 16, *) {
            return Locale.current.region?.identifier ?? "US"
        }
        return Locale.current.regionCode ?? "US"
    }
}
