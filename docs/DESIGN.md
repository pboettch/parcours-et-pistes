# Parcours et Pistes — design and protocol (v1)

This document describes the architecture and the protocol as implemented in `packages/`.
It is the reference for the Flutter apps and for anyone reviewing the security.

## Goals and constraints
- Share search-dog trails (*Recherche Utilitaire* — track + objects; *Man Trailing* — track only)
  between a project creator and participants, plus live positions.
- **No central user database.** Identities are device key pairs; all project data lives on an
  MQTT 5 broker under the project's secret UUID.
- **Nothing readable on the broker** except the minimal key-derivation metadata.
- A default broker/account is preconfigured in the apps and can be replaced.
- Free and open source (MIT). Apps in Flutter (iOS, Android, web); the libraries are pure Dart
  and run on the Dart VM and in browsers.

## Architecture
Three packages in one Dart workspace (root `pubspec.yaml`):

```text
            Flutter apps
                 │
            pep_core ─────────── ProjectSession: maps content onto collections (thin glue)
             │        │
   pep_channel        pep_content
   secure channel     content model
   (opaque bytes)     (no crypto, no MQTT)
```

| Package | Responsibility | Depends on |
|---|---|---|
| `pep_channel` | Transport (MQTT 5), crypto, envelope, owner-signed metadata and access list, `SecureChannel`: collections of opaque items with writer policies, revisions, tombstones, expiry, sync barrier | sodium, mqtt5_client, archive |
| `pep_content` | `Gpx` (with `pep` extensions), `Position`, `MemberProfile`, `ProjectInfo`, `Run`, `RecordedPath`, `TrailInfo`: data types and byte codecs; geometry (`TrackLine`), progress matching (`TrailProgress`), simulated trails and walks (`simulateTrail`, `TrailWalker`) | xml |
| `pep_core` | `ProjectSession` facade (the apps' API), `PepCollections` (content ↔ collection mapping), `pep` CLI | both |

The channel never interprets item bodies: every security decision uses the topic, the signer
and the signed envelope header only. **Adding a content type** = a data type in `pep_content` +
a collection in `PepCollections` (declared in the access list of new projects, or added to
existing ones by the owner). Clients that do not know a collection still enforce its access
rules and ignore its content.

**One writer per item.** Rather than resolving concurrent edits, every item has a single
writer: the owner (project information, runs), the member it belongs to (`self` items:
profile, position, recorded path) or the member the owner assigned it to (tracks). The owner
re-signs items whose writer changes; nothing merges or deletes other members' items.

## Cryptography
| Purpose | Primitive (libsodium) |
|---|---|
| Password → key | Argon2id (`crypto_pwhash`, default t=3, 64 MiB), 16-byte random salt |
| Subkeys | `crypto_kdf` (BLAKE2b) context `PEPv1key`: id 1 = data key, id 2 = key-check key, id 3 = pseudonym key |
| Key check | `BLAKE2b-128(key = check key, "pep-key-check")`, public in `meta` |
| Encryption | XChaCha20-Poly1305 (IETF AEAD), random 24-byte nonce, AD = topic |
| Signatures | Ed25519; member id = unpadded base64url of the 32-byte public key |
| Compression | raw deflate, prefixed with the u32 uncompressed length (max 64 MiB) |

KDF parameters read from the broker are bounded (t ≤ 10, m ≤ 256 MiB) against DoS.
On the web, libsodium runs as `sodium.js` (sumo build, WebAssembly): Argon2id at the default
parameters takes ~75 ms in Chromium, ~20 ms on the Dart VM (2026 desktop hardware).

## Identities, roles, trust
- **One identity per user**, an Ed25519 key pair; the member id (unpadded base64url of the
  public key) is project-independent. The 32-byte seed is kept in secure storage and **copied to
  the user's other devices** with `IdentityExport` (Argon2id + XChaCha20-Poly1305 under a
  passphrase, ~130 characters, QR-friendly). A lost device means the identity must be considered
  compromised: the user creates a new one and is re-added by friends and projects.
- `fingerprintOf(memberId)`: 80 bits of SHA-256 as `XXXX-XXXX-XXXX-XXXX` (Crockford base32),
  for people to compare when adding each other.
- **Owner**: the project creator. Signs `meta` and the access list.
- **Participants**: anyone holding the password.
- What each may write is set per collection by its **writer policy** in the access list:
  `owner`, `assigned` (each item by the member the owner assigned it to in the access list,
  else by the owner; e.g. a track by its setter) or `self` (any member, only the item whose id
  is their member pseudonym).
- **Assignment** (`SecureChannel.assign`, facade `assignTrack`): the owner names the writer of an
  item, which may not exist yet. The owner may write assigned items too — the protocol needs it
  to re-sign — but the facade lets only the assignee change them. On reassignment the owner
  first re-signs the current revision (rev + 1, valid under both access lists), then publishes
  the access list: sessions joining later, which check the signer against the new list, still
  accept the item, and the new writer's first edit follows it. A restricted item gets the new
  writer as a recipient (refused if the owner cannot read it). Remaining race:
  an edit the former writer sends at the very moment of the reassignment is rejected by every
  client but replaces the broker's retained copy, so members joining later do not see the item
  until its next revision.
- The **join link** carries the owner id; it is the trust anchor: the access list and `meta`
  must be signed by that key. The owner is the project's creator and **never changes** (no
  ownership transfer, user decision 2026-10-19): handing a project over means creating a new one
  from a local copy (see *Compromised project*).

### Member pseudonyms and devices
Items of `self` collections are stored under a **pseudonym**, never the member id:
`b64u(BLAKE2b-128(key = pseudonym key, "pep-self-v1" | member public key))`, the pseudonym key
being subkey 3 of the channel master key. Without the password, topics cannot be linked to
members, nor one member across projects. A `.tag` suffix gives each device of a user its own
item (positions; a recording device's rolling points and full track segments):
`b64u(first 9 bytes of BLAKE2b-128(key = pseudonym key, "pep-device-v1" | member public key |
device name))` — device names (stable per installation) never appear in topics either.
The project password never changes (see *Compromised project*), so neither do pseudonyms and
tags.

### Restricted items (per-track visibility)
`put(..., recipients:)` (facade: `publishTrack(visibleTo:)`) encrypts the body with a fresh
content key and seals that key for each recipient (libsodium sealed box to the X25519 form of
their Ed25519 key). The owner and the publisher are always added; recipient keys must be valid
Ed25519 points (blocks naming others are rejected). Envelope flag bit2 marks the
body as a restricted block:
```text
u8 count | count × (recipient public key[32] | sealed content key[80])
| nonce[24] | XChaCha20-Poly1305(content key, ad = topic, flags u8 | payload)
```
Other members see that the item exists and who may read it, not its content. Re-sealing
(reassignment) keeps the block as is, so no one needs to read it.
Changing the recipients = publishing a new revision; members dropped from the list lose the item
(but keep what they already downloaded).

## Collections of Parcours et Pistes (`PepCollections`)
| Collection | Item id | Writers | TTL | Body (`pep_content`) |
|---|---|---|---|---|
| `info` | `project` | owner | — | `ProjectInfo` JSON: name, desc, disc (`ru`/`mt`), extra |
| `track` | random | assigned | — | the GPX document (UTF-8), see *Track content* |
| `member` | member pseudonym | self | — | `MemberProfile` JSON: name, bot?, extra? |
| `pos` | member pseudonym [`.tag(device)`] | self | project setting (default 30 min) | `Position` JSON: lat, lon, ts (fix time), alt?, acc?, hdg?, spd? |
| `run` | random | owner | — | `Run` JSON: track (id), dog, handler?, src [{m: member id, t: since ms}], start?, end?, extra? |
| `path_pt` | member pseudonym `.tag(r<slot 0–19>[-device])` | self | — | `Position` JSON: one of the last 20 points recorded by a device, rolling |
| `path` | member pseudonym `.tag(f<segment>[-device])` | self | — | `RecordedPath` JSON: the points the device recorded, 1000 per segment, `{"v":1, "p":[t, lat, lon, Δt, Δlat, Δlon, …], "extra"?}` (ms, 10⁻⁶ degree; first point absolute, then differences) |

Collections added by a version are declared in new projects; the owner's session adds them to
older projects when it joins (`ProjectSession.ensureCollections`).

### Runs: the dog's position
A dog carries no phone. Its position is the one shared by a member the project owner designates
in the run: the official follower of the handler's group, or a **bot** member
(`MemberProfile.bot`) such as a service feeding a GPS collar (Tractive) into the project with
its own identity. The designated member can change during the day; `Run.src` keeps every
change, so the dog's path is the concatenation of each source's path over its period.

While a member is the source of an unfinished run (default `PathMode.whenSource`), its sessions
**record** each of its positions (accuracy ≤ 50 m), all three written by the recorder only:
- the live position (`pos`), as for every member;
- the point on the next of **20 rolling items** (`path_pt`, slot = counter mod 20; the fix times
  give the order): the last ~100 s at one point every 5 s;
- every 30 s (`ProjectSession.pathInterval`, also when recording stops and on `close`), the
  **full track** of the device (`path`): every point it ever recorded in the project, in
  segments of 1000 points (~1.4 h at one point every 5 s; a few kB) so that messages stay small:
  only the open segment is republished.

A member joining reads the run's current source, that member's full track(s) and rolling
points, and merges them by time (`ProjectSession.path`); the rolling points cover what came
after the last full track. A device without network keeps recording: the points stay in the full
track and go out with its next publication. A restarted app continues its device's full track
and rolling items from what it finds in the project. No server-side service is involved.

`ProjectSession.dogPath` combines the recorded path of each successive source over its period and
the live position; `runProgress` matches the path against the track (`TrailProgress`: first
confirmed start near the beginning of the track, then a forward-only cursor limited by the
distance actually travelled, until the path leaves the track for good — ported from the CCO
prototype).

## Topic layout
Base `pep/v1` (configurable). All messages are retained except `sync` probes.

```text
<base>/<uuid>/meta                owner-signed plaintext: KDF params, key check (never changes)
<base>/<uuid>/acl                 sealed access list, signed by the owner
<base>/<uuid>/<collection>/<id>   sealed items (ephemeral collections: MQTT message expiry = TTL)
<base>/<uuid>/sync/<nonce>        empty, non-retained barrier probe
```
Collection names: `[a-z][a-z0-9_]{0,31}`, not `meta`/`acl`/`sync`. Ids: `[A-Za-z0-9_.-]{1,64}`.

Clients subscribe to `<base>/<uuid>/#` only — with a literal UUID. The UUID (122 random bits,
from libsodium's CSPRNG) is a secret: see *Broker requirements*.

## Wire formats
**meta** (plaintext): `signature[64] | json`, signature over
`"pep-meta-v1" | lp16(topic) | json`, with
`json = {"v":1, "kdf":{"alg":"argon2id13","ops":…,"mem":…,"salt":b64u}, "check":b64u}`.

**Sealed payload** (access list and items):
```text
"PEP1" | version u8 (=1) | nonce[24] | XChaCha20-Poly1305(data key, AD = topic, plaintext)
plaintext = header | signer public key[32] | signature[64] | body
header    = flags u8 (bit0 deflated, bit1 deleted, bit2 restricted) | rev u32 | time u64 (ms since epoch, UTC)
signature = Ed25519("pep-sig-v1" | lp16(topic) | header | body)
```
Binding the topic both as AD and in the signature prevents moving a payload to another topic
or project. `lp16` = u16 big-endian length prefix. The header gives the channel what it needs
(ordering, tombstones, expiry) without reading the body.

**Access list** body (JSON): `{"v":1, "owner":member id,
"collections":{name:{"w":"owner"|"assigned"|"self", "ttl":seconds?}},
"assign":{collection:{item id: member id}}?}`.

The access list keeps no unknown fields: a new field needs a new version.

Content bodies are defined by `pep_content` (see the collections table); JSON documents carry
`"v":1`, unknown fields are preserved, higher versions are rejected.

## Track content (GPX)
Everything related to a track travels **inside the GPX 1.1 document**, which is the item body
as is; id, revision, publish time and deletion are channel data.
- Display name / description: `<metadata><name>` / `<desc>` (fallback: first `<trk><name>`).
- The trail: `<trk>` (and `<rte>`, read as a single-segment track).
- RU objects: `<wpt>` with `<type>pep:object</type>`.
- Additional information: custom `<extensions>` sections in the namespace
  `urn:parcours-et-pistes:gpx:1` (prefix `pep`) — at file level (`<metadata><extensions>`,
  root `<extensions>`), on waypoints/objects, tracks/routes and points.
- Useful places (parking, meeting point): `<wpt>` with `<type>pep:place</type>`, `<name>` = label.
- Official RU trail details: `<metadata><extensions><pep:trail code="V1" level="I" setter="…"/>`
  (`TrailInfo`). **Placeholder** for the official trail sheet ("description de pose"): the
  organizers' part (prepared beforehand) and the judge's part (filled in during the trail on a
  tablet) will be added as further `pep:` elements, and the app will generate the printable
  documents from them.
- GPX files from other tools (e.g. Visorando) mark nothing: `objectsFromWaypoints` turns plain
  waypoints that are not at the start or end of the track into objects.
- Foreign extensions (e.g. Garmin) are preserved on parse → write; each preserved element carries
  its own namespace declarations. Other unknown elements are dropped when a GPX is rewritten
  (the GPX string is published byte for byte unless an app rewrites it).

## Client rules
- Decrypt, verify the signature, then authorize: access list → owner; items → the writer
  policy of their collection. Items of undeclared collections are rejected. Failures are
  reported (`MessageRejected`) and ignored. Content that fails to decode is reported by the
  facade the same way.
- Ordering: `(rev, time)` from the header; lower or equal versions are ignored (replay
  protection for clients that saw the newer one). A publisher uses the last known rev + 1. Two
  writers publishing the same rev at the same millisecond (the owner re-signing while the
  assignee edits; two devices of one member): the one received last wins, as at the broker
  (which keeps the last one retained and delivers a topic in one order), so clients converge
  on the broker's version. Two owner devices changing one run at the same moment still lose
  one of the two changes (the same one everywhere).
- **Reconnecting**: after the transport reconnects, a session subscribes again (if the new
  connection lost the subscription) and waits for a sync barrier before it publishes anything,
  so that it acts on the current access list (e.g. a former assignee learns of a reassignment
  first). A reconnect replaces a reload still running; only the latest reload's failure fails a
  write (`TransportException`), and the next write tries again. `Mqtt5Transport` drops a
  connection that stops answering pings (keep-alive; twice the ping period is announced to the
  broker) and reconnects by itself, also after the broker closed it (growing delay, reset after
  a connection that lasted); concurrent `connect()` calls share one connection, and a
  `disconnect()` during a connect aborts it. mqtt5_client may report a socket reset by the
  broker as an uncaught error: apps and the CLI run in a zone that handles those.
- A session's writes (items, access list) run **one at a time**, in call order. `close` waits
  (a few seconds at most) for those already called; writes called after `close` or
  `deleteChannel` fail.
- Revisions above `maxItemRev` (2³² − 1 − 2²⁰) are rejected unless signed by the owner, leaving
  room for the revisions the owner adds when re-signing.
- Whatever fails while handling a message (invalid format, out-of-range publish time, …) only
  rejects that message (`MessageRejected`).
- Deletion: a signed tombstone (flag `deleted`, empty body) for persistent collections; an
  empty retained payload for ephemeral ones.
- Items rejected for lack of permission (or an undeclared collection) are kept pending and
  re-checked whenever the access list changes (e.g. an assignment racing the assignee's first
  publish, or a collection declared after a newer app published into it).
- Ephemeral items are shown only while their publish time is within the TTL (and at most
  5 min in the future); the broker drops them via message expiry.
- **Sync barrier**: after subscribing, a client publishes an empty non-retained message to
  `sync/<nonce>` and waits for it; everything received before it is the complete retained
  state. `join` does this before returning.
- **The key never changes**: `meta` is accepted only signed by the owner of the join link; once
  known, metadata with another key check is rejected, even signed by the owner.
- **Joining**: subscribe, sync barrier, verify `meta` against the link's owner, derive the key
  from the password (`WrongPasswordException` if the key check differs), then process the
  access list and the items that arrived meanwhile.
- **Delete** (owner): clear all retained topics (meta last).
- Items are discovered from their own retained topics; there is no index, so track owners and
  members can publish without the owner.

## Join link
`<prefix>#p=<uuid>&o=<owner id>[&b=<broker url>][&t=<topic base>]` — everything in the
fragment (never sent to web servers). Default prefix `parcoursetpistes://join`. The password is
never part of the link.

## Transport
`Transport` interface (awaitable QoS 1 publish and subscribe, retained, message expiry,
reconnect with re-subscription). Implementations: `Mqtt5Transport` (`mqtt5_client`; VM: mqtt,
mqtts, ws, wss; browser: ws, wss) and `MemoryTransport` (tests). Apps may plug in a platform
client, e.g. for background location sharing.

TLS: normal certificate validation; for self-hosted brokers with self-signed certificates,
`BrokerConfig.pinnedCertificates` accepts server certificates by SHA-256 fingerprint (VM only;
browsers apply their own trust). Broker refusals (bad credentials, ACL-denied publish or
subscribe) surface as `TransportException`.

## Broker requirements (production)
- MQTT 5 with message expiry; retained messages persisted indefinitely; TLS on all listeners.
- **Deny wildcard subscriptions above the UUID level** (`pep/v1/#`, `pep/v1/+/…`) for normal
  accounts so UUIDs cannot be enumerated. Plain mosquitto ACLs cannot express this; use an auth
  plugin (e.g. mosquitto-go-auth) or a broker with richer authorization (e.g. EMQX).
- Optional hardening: per-project write restrictions (see threat model).

## Threat model (summary)
| Attacker | Can | Cannot |
|---|---|---|
| Broker admin / network observer (TLS off) | see topic names (channel UUIDs, collections, pseudonyms), sizes, timing, KDF params; delete or replay retained messages | read any content; learn member ids or link members across projects; forge messages |
| Knows the UUID, not the password | delete/replace retained messages (vandalism), replay old ciphertexts to new joiners | read or forge; replace the metadata (owner-signed) |
| Holds the password | read everything not restricted; write `self` items for themselves (incl. their recorded path) | read restricted items they are not a recipient of; forge the access list, owner items, tracks, or other members' items |
| Track owner | write/delete the tracks assigned to them | change other tracks or the access list |

Known limitations: deletion/vandalism by UUID holders needs broker-side ACLs (an empty `meta`
or access list also reads as "project deleted": apps must not delete local copies on that
event); a new joiner can be served an old (replayed) revision of an item or of the access list
— an owner session that joins on a replayed access list would build its next change on it;
nobody can be excluded from a project, and the owner cannot hand it over (see *Compromised
project*); items re-signed by the owner (reassignment) are attributed to the owner.

### Compromised project
The project password cannot be changed (user decision, 2026-10-19; a password change only hides
what comes next anyway: whoever had the password keeps what they decrypted). When a project has
been compromised (password or link leaked, a member to exclude) or is to be handed over, the
(new) owner creates a **new project** from their local copy — any member can create a project
from one they have synced — shares the new link and password with the members to keep, and the
old one is deleted.
