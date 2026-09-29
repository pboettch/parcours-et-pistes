# TODO — app layer

Items that belong to the Flutter apps (the libraries already provide what they need).

## Identity and devices
- [ ] First start: generate the identity (`Identity.generate`), keep the seed in the platform's
      secure storage (Keychain / Keystore / web: encrypted IndexedDB).
- [ ] Generate a **device id** once per installation (`[A-Za-z0-9_-]{1,32}`) and pass it as
      `deviceId` to `ProjectSession.create/join` (positions per device).
- [ ] Backup / move to another device: `IdentityBackup.export` shown as a QR code (and as text),
      `IdentityBackup.import` by scanning it. Explain that a lost device means creating a new
      identity (one identity per user, copied — decision of 2026-09-29).
- [ ] Show the user's own fingerprint (`Identity.fingerprint`).

## Friends (contacts)
- [ ] Device-local contact list: member id, display name, fingerprint, optional note.
- [ ] Add a friend by scanning their QR "contact card" (member id + display name), ideally in
      person; show both fingerprints for comparison.
- [ ] Sync the contact list (and the list of joined projects: link + password) between the
      devices of one user. Options to decide:
      - include it in the identity backup (re-export after changes), or
      - a personal `SecureChannel` owned by the user, whose password and channel id are derived
        from the identity seed (needs small library hooks: a deterministic channel id for
        `SecureChannel.create`, and a key given directly instead of a password).

## Projects
- [ ] Project creation: pick friends; per track choose "everyone" or selected friends →
      `publishTrack(visibleTo: {...})`. Friends still need the join link + password to become
      members; visibility only restricts among members.
- [ ] Choose editors among friends (`addEditor`).
- [ ] Ownership transfer UI: owner picks a member → `offerOwnership`; on `OwnershipOffered`, ask
      the member → `acceptOwnership`. Afterwards share only new join links (see DESIGN.md,
      threat model).
- [ ] Password change flow: on `PasswordChanged`, ask for the new password → `unlock`, then
      re-publish own profile/position (other members' items are cleared by the owner).
- [ ] Show "visible to …" on restricted tracks (`Track.visibleTo`), resolving member ids to
      contact names.
- [ ] Surface `MessageRejected` events in a diagnostics view.

## Positions
- [ ] Background location sharing on iOS and Android (OwnTracks as behavioural reference):
      periodic `publishPosition`, stop with `clearPosition`.

## RU specifics
- [ ] Define the `pep:` GPX extension elements for RU track details and objects (to come from
      the project owner), then add typed accessors in `pep_content`.
