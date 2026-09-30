import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pep_core/pep_core.dart';

import '../screens/menu.dart';
import '../screens/track_sheet.dart';
import '../state/app_state.dart';
import '../util.dart';
import 'base_layers.dart';

/// The main screen: the map, centred on the user, with the project's tracks,
/// members and dogs; everything else is in the menu.
class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.app});

  final AppState app;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  var _ready = false;
  var _follow = true;
  String? _fittedProject, _fittedTrack;
  Position? _followed;
  Timer? _clock;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    unawaited(app.startLocating());
    // Ages ("il y a 2 min") and expiries move on without events.
    _clock = Timer.periodic(const Duration(seconds: 10), (_) => setState(() {}));
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    _clock?.cancel();
    super.dispose();
  }

  void _onApp() {
    if (app.error case final e?) {
      app.error = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? showError(context, e) : null);
    }
    if (_ready) _moveCamera();
    setState(() {});
  }

  /// Fits the project's tracks when a project opens, the track when one gets
  /// selected, and follows the user otherwise (until the map is dragged).
  void _moveCamera() {
    if (!_fit()) _followMe();
  }

  /// Fits the camera to a newly opened project or selected track; true if it did.
  bool _fit() {
    final s = app.session;
    if (s != null && _fittedProject != s.projectId) {
      _fittedProject = s.projectId;
      _fittedTrack = app.selectedTrackId;
      final pts = [for (final t in s.tracks.values) ...t.points.map(ll)];
      if (pts.length > 1) {
        _follow = false;
        _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: const EdgeInsets.all(48)));
        return true;
      }
    }
    if (app.selectedTrackId != _fittedTrack) {
      _fittedTrack = app.selectedTrackId;
      final t = s?.tracks[_fittedTrack];
      if (t != null && t.points.length > 1) {
        _follow = false;
        _map.fitCamera(
          CameraFit.coordinates(
            coordinates: t.points.map(ll).toList(),
            padding: const EdgeInsets.fromLTRB(48, 96, 48, 220),
          ),
        );
        return true;
      }
    }
    return false;
  }

  /// In follow mode, keeps the user's new positions in view.
  void _followMe() {
    final me = app.myPosition;
    if (!_follow || me == null || identical(me, _followed)) return;
    _followed = me;
    _map.move(ll(me), math.max(_map.camera.zoom, 15));
  }

  void _locate() {
    setState(() => _follow = true);
    if (app.myPosition case final p?) {
      _map.move(ll(p), math.max(_map.camera.zoom, 16));
    } else {
      unawaited(app.startLocating());
      if (app.locationError case final e?) showError(context, e);
    }
  }

  /// Tapping near a track selects it.
  void _onTap(TapPosition _, LatLng at) {
    final s = app.session;
    if (s == null) return;
    final metersPerPixel = 156543.03 * math.cos(at.latitude * math.pi / 180) / math.pow(2, _map.camera.zoom);
    (String, double)? best;
    for (final t in s.tracks.values) {
      final d = t.line?.nearest(at.latitude, at.longitude).distance;
      if (d != null && d < 24 * metersPerPixel && (best == null || d < best.$2)) best = (t.id, d);
    }
    if (best != null) app.selectTrack(best.$1);
  }

  @override
  Widget build(BuildContext context) {
    final s = app.session;
    final selected = s?.tracks[app.selectedTrackId];
    final runId = app.selectedRunId;
    return Scaffold(
      drawer: MenuDrawer(app: app),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(46.6, 2.4),
              initialZoom: 6,
              maxZoom: 21,
              onTap: _onTap,
              onMapReady: () {
                _ready = true;
                // Not synchronously: the tile layer would miss the first camera move.
                WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _moveCamera() : null);
              },
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _follow) setState(() => _follow = false);
              },
            ),
            children: [
              ...app.layer.build(),
              if (s != null) ..._projectLayers(s, selected, runId),
              ..._myLayers(),
              Scalebar(alignment: Alignment.bottomLeft, padding: const EdgeInsets.fromLTRB(12, 0, 0, 28)),
              RichAttributionWidget(
                alignment: AttributionAlignment.bottomLeft,
                attributions: [TextSourceAttribution(app.layer.attribution)],
              ),
            ],
          ),
          _topBar(context, s),
          _sideButtons(context, s),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s != null && runId != null && s.runs[runId] != null) RunCard(app: app, runId: runId),
                  if (s != null && selected != null) TrackCard(app: app, track: selected),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- layers

  List<Widget> _projectLayers(ProjectSession s, Track? selected, String? runId) {
    final run = runId == null ? null : s.runs[runId];
    final runTrack = run == null ? null : s.tracks[run.track];
    final line = selected?.line;
    final progress = runId == null ? null : s.runProgress(runId);
    final path = runId == null ? const <TimedPoint>[] : s.dogPath(runId);
    final dogSource = run?.source;
    final dogLive = dogSource == null ? null : s.positions[dogSource];
    final GeoPoint? dog = dogLive ?? (path.isEmpty ? null : path.last);
    final objects = selected?.document.objects.toList() ?? const <GpxWaypoint>[];
    final dogLine = runTrack?.line;
    final nearest = dog == null || dogLine == null ? null : dogLine.nearest(dog.lat, dog.lon);

    return [
      if (app.showCorridors && line != null)
        PolylineLayer(
          polylines: [
            for (final (r, c) in [(300.0, Colors.red), (200.0, Colors.orange), (100.0, Colors.green)])
              Polyline(
                points: line.points.map(ll).toList(),
                strokeWidth: 2 * r,
                useStrokeWidthInMeter: true,
                color: c.withValues(alpha: 0.15),
                strokeCap: StrokeCap.round,
                strokeJoin: StrokeJoin.round,
              ),
          ],
        ),
      PolylineLayer(
        polylines: [
          for (final t in s.tracks.values)
            if (t.id != selected?.id)
              Polyline(
                points: t.points.map(ll).toList(),
                strokeWidth: 3.5,
                color: const Color(0xFF3F6FC8),
                borderStrokeWidth: 1.5,
                borderColor: Colors.white,
              ),
          if (selected != null)
            Polyline(
              points: selected.points.map(ll).toList(),
              strokeWidth: 6,
              color: const Color(0xFF1565C0),
              borderStrokeWidth: 1.5,
              borderColor: Colors.white,
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
          if (progress != null && progress.started)
            Polyline(points: progress.done.map(ll).toList(), strokeWidth: 5, color: Colors.red),
          if (path.length > 1)
            Polyline(
              points: path.sublist(progress?.anchor ?? 0).map(ll).toList(),
              strokeWidth: 3,
              color: Colors.purple,
            ),
          if (app.showDistance && nearest != null && dog != null)
            Polyline(
              points: [ll(nearest), ll(dog)],
              strokeWidth: 3,
              color: Colors.grey.shade700,
              pattern: StrokePattern.dashed(segments: const [8, 6]),
            ),
        ],
      ),
      MarkerLayer(
        markers: [
          for (final t in s.tracks.values)
            if (t.id != selected?.id && t.points.isNotEmpty) _trackLabel(t),
          if (selected != null && selected.points.isNotEmpty) ...[
            _pin(ll(selected.points.first), Colors.green.shade700, Icons.flag, 'Départ'),
            _pin(ll(selected.points.last), Colors.red.shade700, Icons.sports_score, 'Arrivée'),
          ],
          for (final (i, o) in objects.indexed) _object(ll(o), '${i + 1}', o.name ?? 'Objet ${i + 1}'),
          for (final p in selected?.document.places ?? const <GpxWaypoint>[])
            _pin(ll(p), Colors.indigo, Icons.local_parking, [p.name, p.description].nonNulls.join(' — ')),
          if (app.showDistance && nearest != null && dog != null)
            Marker(
              point: LatLng((nearest.lat + dog.lat) / 2, (nearest.lon + dog.lon) / 2),
              width: 80,
              height: 24,
              child: _label(metres(nearest.distance)),
            ),
          for (final e in s.positions.entries)
            if (e.key != s.memberId && e.key != dogSource) _member(s, e.key, e.value),
          if (dog != null && run != null)
            _dog(run.dog, dogLive == null ? 'dernier point ${ago(path.last.time)}' : ago(dogLive.time), dog),
        ],
      ),
    ];
  }

  List<Widget> _myLayers() {
    final me = app.myPosition;
    if (me == null) return const [];
    return [
      CircleLayer(
        circles: [
          if (me.accuracy != null)
            CircleMarker(
              point: ll(me),
              radius: me.accuracy!,
              useRadiusInMeter: true,
              color: Colors.blue.withValues(alpha: 0.12),
              borderColor: Colors.blue.withValues(alpha: 0.4),
              borderStrokeWidth: 1,
            ),
        ],
      ),
      MarkerLayer(
        markers: [
          Marker(
            point: ll(me),
            width: 22,
            height: 22,
            child: Container(
              decoration: BoxDecoration(
                color: app.sharing ? Colors.blue : Colors.blueGrey,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Marker _pin(LatLng p, Color c, IconData icon, String tip) => Marker(
    point: p,
    width: 32,
    height: 32,
    child: Tooltip(
      message: tip,
      triggerMode: TooltipTriggerMode.tap,
      child: CircleAvatar(
        backgroundColor: Colors.white,
        child: CircleAvatar(
          radius: 13,
          backgroundColor: c,
          child: Icon(icon, size: 16, color: Colors.white),
        ),
      ),
    ),
  );

  /// Code (or name) of an unselected track at its start; tap to select.
  Marker _trackLabel(Track t) => Marker(
    point: ll(t.points.first),
    width: 64,
    height: 22,
    child: Center(
      child: GestureDetector(
        onTap: () => app.selectTrack(t.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: levelColor(t.trail?.level),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white, width: 1.5),
          ),
          child: Text(
            t.trail?.code ?? t.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    ),
  );

  Marker _object(LatLng p, String n, String tip) => Marker(
    point: p,
    width: 26,
    height: 26,
    child: Tooltip(
      message: tip,
      triggerMode: TooltipTriggerMode.tap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.orange.shade800,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Text(
          n,
          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
        ),
      ),
    ),
  );

  Marker _member(ProjectSession s, String id, Position p) {
    final name = memberName(s, id);
    final bot = s.members[id]?.bot ?? false;
    final stale = DateTime.now().difference(p.time) > const Duration(minutes: 2);
    return Marker(
      point: ll(p),
      width: 34,
      height: 34,
      child: Tooltip(
        message: '$name — ${ago(p.time)}',
        triggerMode: TooltipTriggerMode.tap,
        child: Opacity(
          opacity: stale ? 0.5 : 1,
          child: CircleAvatar(
            backgroundColor: Colors.white,
            child: CircleAvatar(
              radius: 14,
              backgroundColor: Colors.teal,
              child: bot
                  ? const Icon(Icons.smart_toy, size: 16, color: Colors.white)
                  : Text(name.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white)),
            ),
          ),
        ),
      ),
    );
  }

  Marker _dog(String name, String when, GeoPoint p) => Marker(
    point: ll(p),
    width: 40,
    height: 40,
    child: Tooltip(
      message: '$name — $when',
      triggerMode: TooltipTriggerMode.tap,
      child: CircleAvatar(
        backgroundColor: Colors.white,
        child: CircleAvatar(
          radius: 17,
          backgroundColor: Colors.red.shade700,
          child: const Icon(Icons.pets, size: 20, color: Colors.white),
        ),
      ),
    ),
  );

  Widget _label(String text) => Center(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    ),
  );

  // ------------------------------------------------------------ controls

  Widget _topBar(BuildContext context, ProjectSession? s) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Builder(
            builder: (context) => FloatingActionButton.small(
              heroTag: 'menu',
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(context).openDrawer(),
              child: const Icon(Icons.menu),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(20),
              color: Theme.of(context).colorScheme.surface,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => openProjects(context, app),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (app.busy)
                        const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        Icon(
                          s == null ? Icons.folder_off_outlined : (s.locked ? Icons.lock : Icons.cloud_done_outlined),
                          size: 18,
                        ),
                      if (s != null && s.recordingPath) ...[
                        const SizedBox(width: 6),
                        Tooltip(
                          message: s.pendingPathPoints == 0
                              ? 'Votre position est enregistrée (position du chien)'
                              : '${s.pendingPathPoints} positions en attente de connexion',
                          child: Icon(Icons.pets, size: 18, color: Colors.red.shade400),
                        ),
                        if (s.pendingPathPoints > 0)
                          Text(' ${s.pendingPathPoints}', style: const TextStyle(fontSize: 12)),
                      ],
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          s == null ? (app.busy ? 'Connexion…' : 'Aucun projet') : s.project.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _sideButtons(BuildContext context, ProjectSession? s) => Positioned(
    right: 12,
    top: 0,
    bottom: 0,
    child: SafeArea(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          PopupMenuButton<BaseLayer>(
            tooltip: 'Fond de carte',
            onSelected: app.setLayer,
            itemBuilder: (_) => [
              for (final l in BaseLayer.all)
                CheckedPopupMenuItem(value: l, checked: l.id == app.layer.id, child: Text(l.label)),
            ],
            child: const _RoundButton(icon: Icons.layers),
          ),
          const SizedBox(height: 10),
          _RoundButton(
            icon: Icons.blur_linear,
            active: app.showCorridors,
            tooltip: 'Corridors 100 / 200 / 300 m',
            onTap: app.toggleCorridors,
          ),
          const SizedBox(height: 10),
          _RoundButton(
            icon: Icons.straighten,
            active: app.showDistance,
            tooltip: 'Distance du chien au parcours',
            onTap: app.toggleDistance,
          ),
          const SizedBox(height: 30),
          _RoundButton(
            icon: app.sharing ? Icons.share_location : Icons.location_disabled,
            active: app.sharing,
            tooltip: app.sharing ? 'Partage de ma position : actif' : 'Partager ma position',
            onTap: s == null ? null : () => app.setSharing(!app.sharing),
          ),
          const SizedBox(height: 10),
          _RoundButton(
            icon: _follow ? Icons.my_location : Icons.location_searching,
            active: _follow,
            tooltip: 'Ma position',
            onTap: _locate,
          ),
        ],
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, this.onTap, this.active = false, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final button = Material(
      elevation: 3,
      shape: const CircleBorder(),
      color: active ? cs.primary : cs.surface,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: active ? cs.onPrimary : (onTap == null && tooltip != null ? cs.outline : null)),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}
