---
name: project-identity-devices
description: User decisions on identities, multiple devices, IdentityBackup (export), per-track visibility and pseudonyms; open IdentityExport proposal
metadata:
  type: project
---

**One identity per user, copied to each device** (decided 2026-09-29, confirmed 2026-10-18 —
*not* per-device keys certified by the user). Lost device ⇒ the user makes a new identity.

**`IdentityBackup` = an identity export** (user's framing, 2026-10-18), with two uses: (1) backup
storage, (2) enabling another device (phone + website). Text `pepid1.…` (~131 chars, QR-friendly):
Argon2id (random salt, default t=3/64 MiB, bounds 1–10 / 8–256 MiB checked on import) +
XChaCha20-Poly1305, AD `pepid1`. Only a non-empty passphrase is required today.

**No identity transfer over the broker (user, 2026-10-18):** a broker-relayed `LinkRequest`
(QR + code, sealed to an ephemeral key) was built and removed on request (commit c106904).

**Open proposal (awaiting the user):** rename to `IdentityExport`; library-generated activation
code (~50 bits, Crockford base32) shown next to the QR for new devices; minimum length for
user-chosen long-term passphrases.

**Also decided (2026-09-29):** ownership transferable — **reverted 2026-10-19**: the owner is
fixed, see [[project-no-password-change]]; per-track visibility = restricted items (content key sealed per
recipient); member ids never in topics (per-channel pseudonyms, which change with the password);
positions per device (`.device` suffix). Friends list / contact exchange are app-layer
(`docs/TODO.md`).

Related: [[project-overview]].
