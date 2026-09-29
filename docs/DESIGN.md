# Parcours et Pistes — design and protocol (v1)

This document describes the protocol as implemented in `packages/pep_core`.
It is the reference for the Flutter apps and for anyone reviewing the security.

## Goals and constraints
- Share search-dog trails (*Recherche Utilitaire* — track + objects; *Man Trailing* — track only)
  between a project creator and participants, plus live positions.
- **No central user database.** Identities are device key pairs; all project data lives on an
  MQTT 5 broker under the project's secret UUID.
- **Nothing readable on the broker** except the minimal key-derivation metadata.
- A default broker/account is preconfigured in the apps and can be replaced.
- Free and open source (MIT). Apps in Flutter (iOS, Android, web); `pep_core` is pure Dart and
  runs on the Dart VM and in browsers.

## Cryptography
| Purpose | Primitive (libsodium) |
|---|---|
| Password → key | Argon2id (`crypto_pwhash`, default t=3, 64 MiB), 16-byte random salt |
| Subkeys | `crypto_kdf` (BLAKE2b) context `PEPv1key`: id 1 = data key, id 2 = key-check key |
| Key check | `BLAKE2b-128(key = check key, "pep-key-check")`, public in `meta` |
| Encryption | XChaCha20-Poly1305 (IETF AEAD), random 24-byte nonce, AD = topic |
| Signatures | Ed25519; member id = unpadded base64url of the 32-byte public key |
| Compression | raw deflate, prefixed with the u32 uncompressed length (max 64 MiB) |

KDF parameters read from the broker are bounded (t ≤ 10, m ≤ 256 MiB) against DoS.
On the web, libsodium runs as `sodium.js` (sumo build, WebAssembly): Argon2id at the default
parameters takes ~75 ms in Chromium, ~20 ms on the Dart VM (2026 desktop hardware).

## Identities, roles, trust
- Each device generates an Ed25519 identity; the 32-byte seed is kept in secure storage.
- **Owner**: the project creator. Signs `meta` and the project document.
- **Editors**: member ids listed in the project document; may publish and delete tracks.
- **Participants**: anyone holding the password; may publish their own profile and position.
- The **join link** carries the owner id; it is the trust anchor. `meta` and the project document
  must be signed by exactly that key.

## Topic layout
Base `pep/v1` (configurable). All messages are retained except `sync` probes.

```text
<base>/<uuid>/meta            owner-signed plaintext: KDF params, key check, rev
<base>/<uuid>/project         sealed, signed by the owner
<base>/<uuid>/track/<id>      sealed, signed by the owner or an editor (tombstone to delete)
<base>/<uuid>/member/<id>     sealed, signed by member <id>
<base>/<uuid>/pos/<id>        sealed, signed by member <id>; MQTT message expiry = position TTL
<base>/<uuid>/sync/<nonce>    empty, non-retained barrier probe
```

Clients subscribe to `<base>/<uuid>/#` only — with a literal UUID. The UUID (122 random bits,
from libsodium's CSPRNG) is a secret: see *Broker requirements*.

## Wire formats
**meta** (plaintext): `signature[64] | json`, signature over
`"pep-meta-v1" | lp16(topic) | json`, with
`json = {"v":1, "kdf":{"alg":"argon2id13","ops":…,"mem":…,"salt":b64u}, "check":b64u, "rev":n}`.

**Sealed payload** (everything else):
```text
"PEP1" | version u8 (=1) | nonce[24] | XChaCha20-Poly1305(data key, AD = topic, plaintext)
plaintext = flags u8 (bit0 = deflated) | signer public key[32] | signature[64] | body
signature = Ed25519("pep-sig-v1" | lp16(topic) | flags | body)
```
Binding the topic both as AD and in the signature prevents moving a payload to another topic
or project. `lp16` = u16 big-endian length prefix.

**Bodies** (JSON, `"v":1`):
- project: `id, name, desc?, disc ("ru"|"mt"), owner, editors[], settings{posTtl, …}, rev, upd`
- track: `id, rev, upd, gpx` or tombstone `id, rev, upd, deleted:true` — see *Track content*
- member: `name, upd`
- position: `lat, lon, ts, alt?, acc?, hdg?, spd?` (ts in ms since epoch, UTC)

Unknown project settings are preserved; documents with a higher `v` are rejected.

## Track content (GPX)
Everything related to a track travels **inside the GPX 1.1 document**; the JSON wrapper only
carries protocol data (id, revision, timestamp, tombstone flag).
- Display name / description: `<metadata><name>` / `<desc>` (fallback: first `<trk><name>`).
- The trail: `<trk>` (and `<rte>`, read as a single-segment track).
- RU objects: `<wpt>` with `<type>pep:object</type>`.
- Additional information: custom `<extensions>` sections in the namespace
  `urn:parcours-et-pistes:gpx:1` (prefix `pep`) — at file level (`<metadata><extensions>`,
  root `<extensions>`), on waypoints/objects, tracks/routes and points. The exact elements for
  RU details are still to be specified.
- Foreign extensions (e.g. Garmin) are preserved on parse → write; each preserved element carries
  its own namespace declarations. Other unknown elements are dropped when a GPX is rewritten
  (the GPX string is published byte for byte unless an app rewrites it).

## Client rules
- Decrypt, verify the signature, then authorize: project → owner; track → owner or current
  editor; member/pos → the member named in the topic. Failures are reported and ignored.
- Revisions: project, meta and each track carry `rev`; lower or equal revisions are ignored
  (replay protection for clients that saw the newer one). Members/positions use timestamps.
- Tracks signed by a not-yet-listed editor are kept pending and re-checked whenever the
  project document changes (live race between "add editor" and the editor's first publish).
- Positions are shown only while `ts` is within the TTL (and at most 5 min in the future);
  the broker drops them via message expiry.
- **Sync barrier**: after subscribing, a client publishes an empty non-retained message to
  `sync/<nonce>` and waits for it; everything received before it is the complete retained
  state. `join` does this before returning.
- **Password change** (owner): publish new `meta` (rev+1) first — other clients lock and ask
  for the new password — then re-seal the project doc, all tracks (re-signed by the owner,
  rev+1) and tombstones, the owner's profile; clear other members' profiles and positions.
- **Delete project** (owner): clear all retained topics (meta last).
- Tracks are discovered from their own retained topics; there is no index, so editors can
  publish without the owner.

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
| Broker admin / network observer (TLS off) | see topic names, sizes, timing, KDF params; delete or replay retained messages | read any content; forge messages |
| Knows the UUID, not the password | delete/replace retained messages (vandalism), replay old ciphertexts to new joiners | read or forge; fake a password change (meta is owner-signed) |
| Holds the password | read everything; publish own profile/position | forge the project doc or tracks (unless editor); impersonate other members |
| Editor | publish/delete tracks | change settings, editors or password |

Known limitations: deletion/vandalism by UUID holders needs broker-side ACLs; a new joiner can
be served an old (replayed) revision; after a password change, former members keep what they
already downloaded; tracks re-sealed during a password change are attributed to the owner.
