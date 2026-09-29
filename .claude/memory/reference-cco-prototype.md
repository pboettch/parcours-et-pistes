---
name: reference-cco-prototype
description: User's Leaflet website prototype (cco.chien-de-recherche.fr) = GUI reference for the app; local copy in ~/devel/cco-prototype (not in repo, private club data)
metadata:
  type: reference
---

The user's GUI reference is a Python-generated site behind HTTP basic auth: https://cco.chien-de-recherche.fr/.
- The user downloads it themselves. I must never enter the password.
- Local copy (wget, 2026-09-29): `~/devel/cco-prototype/cco.chien-de-recherche.fr/`.

What it contains:
- **`index.html`:** one card per trail (V1..V5, S1..S7, D1..D3). Each card has:
  - a level badge B/I/II/III;
  - lieu-dit and poseur;
  - buttons for the descriptif PDF, the GPX file and the live map;
  - places (Minibus/Cyno parking, Départ, Arrivée), each with a Google Maps / Waze link.
- **`vN.html` (live map, Leaflet):**
  - IGN Plan v2 tiles, with Ortho defined;
  - the track in blue, a start marker (green) and an end marker (red);
  - the middle waypoints are objects;
  - toggleable 100/200/300 m corridors;
  - the distance from the dog to the nearest point of the track;
  - live positions over MQTT, OwnTracks-like JSON on `locations/<user>`. The user "tractive" is the dog, a Tractive collar bridged by tractive2mqtt;
  - the dog's history from an HTTP endpoint (purple line, age selector 2 h..5 d);
  - a progress-matching algorithm (start anchor, monotone cursor along the line), shown as a red "done" part with a %.
- **GPX files:** Visorando exports where all waypoints are GENERIC. There is no object marking, so the importer needs a heuristic.
- **`poseurs/*.pdf`:** the "Description de Pose" form:
  - date, N°, level, poseur, times of pose and of prise de piste;
  - for each object: where it was placed, plus material (tissu/carton/cuir/suspendu);
  - end of the trail, weather and encounters.

The club data (places, names) is private: don't commit it to the public repo without asking. See [[project-gpx-trail-app]].
