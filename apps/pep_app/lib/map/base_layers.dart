import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

const _userAgent = 'fr.parcoursetpistes.pep_app';

/// IGN Géoplateforme WMTS tile URL (no key needed) for [layer].
String _ign(String layer, String format) =>
    'https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=$layer&STYLE=normal'
    '&TILEMATRIXSET=PM&FORMAT=$format&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}';

/// A background map.
class BaseLayer {
  const BaseLayer(this.id, this.label, this.icon, this.tiles, this.attribution);

  final String id;
  final String label;
  final IconData icon;

  /// (URL template, max native zoom), bottom first.
  final List<(String, int)> tiles;
  final String attribution;

  static const ign = BaseLayer('ign', 'IGN Plan', Icons.map_outlined, [
    (
      'https://data.geopf.fr/wmts?SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0&LAYER=GEOGRAPHICALGRIDSYSTEMS.PLANIGNV2'
          '&STYLE=normal&TILEMATRIXSET=PM&FORMAT=image/png&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}',
      19,
    ),
  ], 'Carte © IGN / Géoplateforme');

  static final satellite = BaseLayer('satellite', 'Satellite (IGN)', Icons.satellite_alt_outlined, [
    (_ign('ORTHOIMAGERY.ORTHOPHOTOS', 'image/jpeg'), 19),
  ], 'Photographies aériennes © IGN / Géoplateforme');

  static const osmHiking = BaseLayer('osm-rando', 'OSM Rando', Icons.hiking, [
    ('https://tile.opentopomap.org/{z}/{x}/{y}.png', 17),
    ('https://tile.waymarkedtrails.org/hiking/{z}/{x}/{y}.png', 18),
  ], '© OpenStreetMap contributors, SRTM · OpenTopoMap (CC-BY-SA) · waymarkedtrails.org');

  static const osm = BaseLayer('osm', 'OpenStreetMap', Icons.public, [
    ('https://tile.openstreetmap.org/{z}/{x}/{y}.png', 19),
  ], '© OpenStreetMap contributors');

  static final all = [ign, osmHiking, osm, satellite];

  static BaseLayer byId(String? id) => all.firstWhere((l) => l.id == id, orElse: () => ign);

  List<Widget> build() => [
    for (final (url, maxNative) in tiles)
      TileLayer(urlTemplate: url, maxNativeZoom: maxNative, maxZoom: 21, userAgentPackageName: _userAgent),
  ];
}
