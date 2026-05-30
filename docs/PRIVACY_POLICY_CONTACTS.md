# Privacy policy language: contacts matching

Paste the section below into your hosted privacy policy (the URL
you submit to App Store Connect / link from your website) before
submitting the contacts feature to App Review. Apple's Guideline
5.1.1(ii) requires the privacy policy to disclose how contact
data is used.

---

## Contacts and "Find Your People"

When you tap **Find your people** on the friends tab, Yafa asks
for permission to access your device's Contacts. If you grant
permission, the following happens:

- Phone numbers from your Contacts list are read on your device.
- Each phone number is normalized to international format (E.164)
  and hashed using SHA-256 **on your device**, before any data
  leaves it. Raw phone numbers are never transmitted to or stored
  on Yafa's servers.
- The hashes are sent to Yafa's servers to be compared against
  the hashes of other users' phone numbers. We use these matches
  only to suggest people you may already know on Yafa.
- We do not store, share, or otherwise process the contact list
  itself. We do not contact, advertise to, or message anyone in
  your Contacts.

You can revoke contacts permission at any time in iOS Settings →
Yafa → Contacts. Revoking it does not delete any matches you
have already followed.

### Your own phone number

To allow your friends to find you in their contacts, Yafa may
ask you to save your phone number. If you choose to do so:

- Your phone number is hashed (SHA-256 of its normalized E.164
  form) on your device, and only the hash is sent to and stored
  on Yafa's servers. The raw number itself is never transmitted
  or persisted.
- The hash is used only for contact matching as described above.
- You can remove your phone number at any time from
  **Profile → Phone Number → Remove**. Removing it instantly
  disables the matching from contacts back to your account.

---

## Apple data-collection labels (App Store Connect → App Privacy)

When filing the App Privacy questionnaire in App Store Connect,
declare:

- **Contacts (Phone Number)**: *Collected* → Linked to user →
  Used for **App Functionality** (Find Friends).
  - Note: only the hash is transmitted, not the raw number.
- **Contacts**: *Not collected*. (The contact list itself never
  leaves the device — only hashes derived from it do, and those
  are listed under Phone Number above.)
