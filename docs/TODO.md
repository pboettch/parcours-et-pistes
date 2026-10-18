# TODO — app layer

Items that belong to the Flutter apps (the libraries already provide what they need).
The web PoC (`apps/pep_app`) already covers: map-first screen with IGN / OSM Rando / OSM / aerial
layers, own position (follow, share), tracks (cards, details, places with Maps/Waze), runs
(create, designate the source, start/finish, dog path / progress / distance / corridors, simulated
dog), participants (editors), identity export/import, join/create/invite (link copy).
Still PoC-grade: storage unencrypted in the browser, French strings inline, no QR codes.

## Identity and devices
- [ ] First start: generate the identity (`Identity.generate`), keep the seed in the platform's
      secure storage (Keychain / Keystore / web: encrypted IndexedDB).
- [ ] Generate a **device id** once per installation (`[A-Za-z0-9_-]{1,32}`) and pass it as
      `deviceId` to `ProjectSession.create/join` (positions per device).
- [x] Add a device (same user on phone and web): device linking, `LinkRequest` — web PoC shows the
      QR code / link and the code, sends by pasting the link (decision 2026-10-18: pairing,
      identity copied, optional password as second factor).
- [ ] Phone app: scan the link QR code (camera); deep link (https URL to the web app carrying the
      link in its fragment) so that a phone camera app can open it directly.
- [ ] Backup: `IdentityBackup.export` as a file / QR code. Explain that a lost device means
      creating a new identity (one identity per user, copied — decision of 2026-09-29).
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

## Runs (events: several dogs on several tracks)
- [ ] Run management UI for the leader: create a run (track, dog, handler), designate the
      position source among members (incl. bots), change it during the day, start/finish.
- [ ] Map: dog marker from the source's position, dog path (`dogPath`), covered part of the track
      and percentage (`runProgress`), distance from the dog to the track, corridors.
- [ ] Tell a member when they become (or stop being) a run's source (recording indicator).

## RU specifics
- [ ] Official trail sheet ("description de pose"): define the `pep:` elements for the
      organizers' part (date, times of pose / prise de piste, start area, objects: placement
      description and material, end, places) and the judge's part (conditions, encounters,
      observations during the trail); extend `TrailInfo`; forms in the app (judge on a tablet);
      generate the official printable documents.
