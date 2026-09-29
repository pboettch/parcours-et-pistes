# pep_content

Content model of **Parcours et Pistes** — pure data and byte codecs, no cryptography, no
networking (the secure transport is `pep_channel`):

- `Gpx`: GPX 1.1 reader/writer — tracks, routes, waypoints (RU objects: `<type>pep:object</type>`),
  and `<extensions>` at every level, preserved on round trip. Custom sections use the namespace
  `urn:parcours-et-pistes:gpx:1` (prefix `pep`): build with `pepElement(...)`, read with
  `.extensions.pep('name')`.
- `Position`, `MemberProfile`, `ProjectInfo` (+ `Discipline`): JSON documents with `encode()` /
  `decode()`.

Invalid content raises `ContentFormatException`.
