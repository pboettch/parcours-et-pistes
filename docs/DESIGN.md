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
| `pep_channel` | Transport (MQTT 5), crypto, envelope, owner-signed metadata and access list, `SecureChannel`: collections of opaque items with writer policies, revisions, tombstones, expiry, sync barrier, password rotation | sodium, mqtt5_client, archive |
| `pep_content` | `Gpx` (with `pep` extensions), `Position`, `MemberProfile`, `ProjectInfo`: data types and byte codecs | xml |
| `pep_core` | `ProjectSession` facade (the apps' API), `PepCollections` (content ↔ collection mapping), `pep` CLI | both |

The channel never interprets item bodies: every security decision uses the topic, the signer
and the signed envelope header only. **Adding a content type** = a data type in `pep_content` +
a collection in `PepCollections` (declared in the access list of new projects, or added to
existing ones by the owner). Clients that do not know a collection still enforce its access
rules and ignore its content.

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
- **Owner**: the project creator. Signs `meta` and the access list.
- **Editors**: member ids listed in the access list.
- **Participants**: anyone holding the password.
- What each may write is set per collection by its **writer policy** in the access list:
  `owner`, `editors` (owner + editors) or `self` (any member, only the item whose id is their
  member id).
- The **join link** carries the owner id; it is the trust anchor. `meta` and the access list
  must be signed by exactly that key.

## Collections of Parcours et Pistes (`PepCollections`)
| Collection | Item id | Writers | TTL | Body (`pep_content`) |
|---|---|---|---|---|
| `info` | `project` | owner | — | `ProjectInfo` JSON: name, desc, disc (`ru`/`mt`), extra |
| `track` | random | editors | — | the GPX document (UTF-8), see *Track content* |
| `member` | member id | self | — | `MemberProfile` JSON: name |
| `pos` | member id | self | project setting (default 30 min) | `Position` JSON: lat, lon, ts (fix time), alt?, acc?, hdg?, spd? |

## Topic layout
Base `pep/v1` (configurable). All messages are retained except `sync` probes.

```text
<base>/<uuid>/meta                owner-signed plaintext: KDF params, key check, rev
<base>/<uuid>/acl                 sealed access list, signed by the owner
<base>/<uuid>/<collection>/<id>   sealed items (ephemeral collections: MQTT message expiry = TTL)
<base>/<uuid>/sync/<nonce>        empty, non-retained barrier probe
```
Collection names: `[a-z][a-z0-9_]{0,31}`, not `meta`/`acl`/`sync`. Ids: `[A-Za-z0-9_-]{1,64}`.

Clients subscribe to `<base>/<uuid>/#` only — with a literal UUID. The UUID (122 random bits,
from libsodium's CSPRNG) is a secret: see *Broker requirements*.

## Wire formats
**meta** (plaintext): `signature[64] | json`, signature over
`"pep-meta-v1" | lp16(topic) | json`, with
`json = {"v":1, "kdf":{"alg":"argon2id13","ops":…,"mem":…,"salt":b64u}, "check":b64u, "rev":n}`.

**Sealed payload** (access list and items):
```text
"PEP1" | version u8 (=1) | nonce[24] | XChaCha20-Poly1305(data key, AD = topic, plaintext)
plaintext = header | signer public key[32] | signature[64] | body
header    = flags u8 (bit0 deflated, bit1 deleted) | rev u32 | time u64 (ms since epoch, UTC)
signature = Ed25519("pep-sig-v1" | lp16(topic) | header | body)
```
Binding the topic both as AD and in the signature prevents moving a payload to another topic
or project. `lp16` = u16 big-endian length prefix. The header gives the channel what it needs
(ordering, tombstones, expiry) without reading the body.

**Access list** body (JSON): `{"v":1, "owner":id, "editors":[ids],
"collections":{name:{"w":"owner"|"editors"|"self", "ttl":seconds?}}}`.

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
  root `<extensions>`), on waypoints/objects, tracks/routes and points. The exact elements for
  RU details are still to be specified.
- Foreign extensions (e.g. Garmin) are preserved on parse → write; each preserved element carries
  its own namespace declarations. Other unknown elements are dropped when a GPX is rewritten
  (the GPX string is published byte for byte unless an app rewrites it).

## Client rules
- Decrypt, verify the signature, then authorize: access list → owner; items → the writer
  policy of their collection. Items of undeclared collections are rejected. Failures are
  reported (`MessageRejected`) and ignored. Content that fails to decode is reported by the
  facade the same way.
- Ordering: `(rev, time)` from the header; lower or equal versions are ignored (replay
  protection for clients that saw the newer one). A publisher uses the last known rev + 1.
- Deletion: a signed tombstone (flag `deleted`, empty body) for persistent collections; an
  empty retained payload for ephemeral ones. Removals are applied even while locked.
- Items rejected for lack of permission (or an undeclared collection) are kept pending and
  re-checked whenever the access list changes (e.g. "add editor" racing the editor's first
  publish, or a collection declared after a newer app published into it).
- Ephemeral items are shown only while their publish time is within the TTL (and at most
  5 min in the future); the broker drops them via message expiry.
- **Sync barrier**: after subscribing, a client publishes an empty non-retained message to
  `sync/<nonce>` and waits for it; everything received before it is the complete retained
  state. `join` does this before returning.
- **Password change** (owner): publish new `meta` (rev+1) first — other clients lock and ask
  for the new password — then re-seal the access list and every item and tombstone the owner
  may write (re-signed by the owner, rev+1); clear ephemeral items, other members' `self`
  items and pending (rejected) messages.
- **Delete** (owner): clear all retained topics (meta last).
- Items are discovered from their own retained topics; there is no index, so editors can
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
| Holds the password | read everything; write `self` items for themselves | forge the access list, owner/editor items, or other members' items |
| Editor | write/delete `editors` collections (tracks) | change the access list or password |

Known limitations: deletion/vandalism by UUID holders needs broker-side ACLs; a new joiner can
be served an old (replayed) revision; after a password change, former members keep what they
already downloaded; items re-sealed during a password change are attributed to the owner.
