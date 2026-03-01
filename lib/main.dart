import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const MapSample(),
    );
  }
}

class MapSample extends StatefulWidget {
  const MapSample({super.key});

  @override
  State<MapSample> createState() => MapSampleState();
}

class MapSampleState extends State<MapSample> {
  final Completer<GoogleMapController> _controller =
      Completer<GoogleMapController>();

  final Set<Factory<OneSequenceGestureRecognizer>> _mapGestureRecognizers = {
    Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
  };

  static const CameraPosition _kGooglePlex = CameraPosition(
    target: LatLng(37.42796133580664, -122.085749655962),
    zoom: 14.4746,
  );

  // --- marker state ---
  Set<Marker> _markers = {};
  bool _loading = true;
  String? _loadError;

  // --- custom info window state ---
  Offset? _infoOffset; // screen position (pixels)
  LatLng? _selectedPos;
  String? _selectedUid;
  String? _selectedTitle;
  String? _selectedSnippet;

  bool _suppressNextMapTap = false;

  @override
  void initState() {
    super.initState();
    _loadMarkers();
  }

  // -----------------------------
  // Custom info window helpers
  // -----------------------------
  Future<void> _showInfo({
    required String uid,
    required LatLng pos,
    required String title,
    required String snippet,
  }) async {
    if (!_controller.isCompleted) return;
    final map = await _controller.future;
    final sc = await map.getScreenCoordinate(pos);
    if (!mounted) return;

    setState(() {
      _selectedUid = uid;
      _selectedPos = pos;
      _selectedTitle = title;
      _selectedSnippet = snippet;
      _infoOffset = Offset(sc.x.toDouble(), sc.y.toDouble());
    });
  }

  Future<void> _repositionInfo() async {
    final pos = _selectedPos;
    if (pos == null) return;
    if (!_controller.isCompleted) return;

    final map = await _controller.future;
    final sc = await map.getScreenCoordinate(pos);
    if (!mounted) return;

    setState(() {
      _infoOffset = Offset(sc.x.toDouble(), sc.y.toDouble());
    });
  }

  void _hideInfo() {
    if (!mounted) return;
    setState(() {
      _infoOffset = null;
      _selectedPos = null;
      _selectedUid = null;
      _selectedTitle = null;
      _selectedSnippet = null;
    });
  }

  // -----------------------------
  // Marker loading
  // -----------------------------
  Future<void> _loadMarkers() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final uids = await _fetchUids();

      final results = await Future.wait(
        uids.map((uid) async {
          final det = await _fetchDetections(uid);
          return (uid: uid, det: det);
        }),
      );

      final markers = <Marker>{};

      for (final item in results) {
        final lat = item.det.lat;
        final lon = item.det.lon;
        if (lat == null || lon == null) continue;

        final pos = LatLng(lat, lon);

        final title = item.det.bestCommonName ?? 'Unknown';
        final snippet = item.det.bestConfidence != null
            ? 'conf ${(item.det.bestConfidence! * 100).toStringAsFixed(1)}%'
            : '';

        markers.add(
          Marker(
            markerId: MarkerId(item.uid),
            position: pos,

            // ✅ Use custom window instead of built-in infoWindow
            onTap: () => _showInfo(
              uid: item.uid,
              pos: pos,
              title: title,
              snippet: snippet,
            ),
          ),
        );
      }

      if (!mounted) return;

      setState(() {
        _markers = markers;
        _loading = false;
      });

      // Optional: hide popup if marker set changed
      _hideInfo();

      // Optional: zoom map to fit markers once loaded
      // await _fitMarkers(markers);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  // --- HTTP ---
  Future<List<String>> _fetchUids() async {
    final uri = Uri.parse('http://66.42.127.17:5000/uids');
    final resp = await http.get(uri);

    if (resp.statusCode != 200) {
      throw Exception('uids failed: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    if (decoded is! List) {
      throw Exception('uids response not a JSON array');
    }

    return decoded.map((e) => e.toString()).toList();
  }

  Future<DetectionSummary> _fetchDetections(String uid) async {
    final uri = Uri.parse('http://66.42.127.17:5000/detections/$uid');
    final resp = await http.get(uri);

    if (resp.statusCode != 200) {
      throw Exception('detections/$uid failed: ${resp.statusCode} ${resp.body}');
    }

    final decoded = jsonDecode(resp.body);
    return DetectionSummary.fromJson(decoded);
  }

  // --- Camera fit helper (optional) ---
  Future<void> _fitMarkers(Set<Marker> markers) async {
    if (markers.isEmpty) return;
    if (!_controller.isCompleted) return;

    final map = await _controller.future;

    double minLat = markers.first.position.latitude;
    double maxLat = markers.first.position.latitude;
    double minLng = markers.first.position.longitude;
    double maxLng = markers.first.position.longitude;

    for (final m in markers) {
      final lat = m.position.latitude;
      final lng = m.position.longitude;
      minLat = lat < minLat ? lat : minLat;
      maxLat = lat > maxLat ? lat : maxLat;
      minLng = lng < minLng ? lng : minLng;
      maxLng = lng > maxLng ? lng : maxLng;
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    await Future.delayed(const Duration(milliseconds: 150));
    await map.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            gestureRecognizers: _mapGestureRecognizers,
            mapType: MapType.satellite,
            initialCameraPosition: _kGooglePlex,
            onMapCreated: (GoogleMapController controller) {
              if (!_controller.isCompleted) _controller.complete(controller);
            },

            // tap on map hides popup (guarded)
            onTap: (_) {
              if (_suppressNextMapTap) {
                _suppressNextMapTap = false;
                return;
              }
              _hideInfo();
            },

            // keep popup aligned after movement
            onCameraIdle: () async {
              if (_infoOffset != null) {
                await _repositionInfo();
              }
            },

            markers: _markers,
          ),

          // -----------------------
          // Custom info window UI
          // -----------------------
          if (_infoOffset != null)
            Positioned(
              left: _infoOffset!.dx - 160, // adjust width/anchor
              top: _infoOffset!.dy - 190,  // above marker
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) {
                  // prevent tap-through closing popup
                  _suppressNextMapTap = true;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,

                  // prevent map gestures that start on the popup (web)
                  onTap: () {},
                  onDoubleTap: () {},
                  onDoubleTapDown: (_) {},
                  onScaleStart: (_) {},
                  onScaleUpdate: (_) {},
                  onScaleEnd: (_) {},

                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(14),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _selectedTitle ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: _hideInfo,
                                ),
                              ],
                            ),
                            if ((_selectedSnippet ?? '').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _selectedSnippet!,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ],
                            const SizedBox(height: 10),
                            AudioPlayButton(url: 'http://66.42.127.17:5000/detections/$_selectedUid/audio'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Loading / error UI
          if (_loading)
            const Positioned(
              top: 16,
              left: 16,
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Loading markers...'),
                    ],
                  ),
                ),
              ),
            ),

          if (_loadError != null)
            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: Text('Error: $_loadError')),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _loadMarkers,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _loadMarkers,
        child: const Icon(Icons.refresh),
      ),
    );
  }
}


class Grid extends StatelessWidget {
  const Grid({super.key, required this.elements});

  final List<String> elements;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: elements.map((value) {
        return Row(
          children: [
            Text(value),
            SizedBox(width: 4),
            AudioPlayButton(
              url:
                  'http://66.42.127.17:5000/detections/69a3d785fed894a859c69a2c/audio',
              label: 'Play Audio',
            ),
          ],
        );
      }).toList(),
    );
  }
}

class AudioPlayButton extends StatefulWidget {
  final String? url;
  final Uint8List? bytes;
  final String label;

  const AudioPlayButton({super.key, this.url, this.bytes, this.label = "Play"})
    : assert(url != null || bytes != null);

  @override
  State<AudioPlayButton> createState() => _AudioPlayButtonState();
}

class _AudioPlayButtonState extends State<AudioPlayButton> {
  late final AudioPlayer _player;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();

    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _isPlaying = false);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    await _player.setVolume(1.0);
    setState(() => _isPlaying = true);

    await _player.stop();

    if (widget.url != null) {
      await _player.play(UrlSource(widget.url!));
    } else {
      await _player.play(BytesSource(widget.bytes!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: _play,
      child: Text(_isPlaying ? "Playing…" : widget.label),
    );
  }
}

class DetectionSummary {
  final List<Map<String, dynamic>> detections;
  final int? time;

  final double? lat;
  final double? lon;

  DetectionSummary({required this.detections, this.time, this.lat, this.lon});

  factory DetectionSummary.fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) {
      return DetectionSummary(detections: const []);
    }

    final dets = (json['detections'] is List)
        ? (json['detections'] as List)
              .whereType<Map>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList()
        : <Map<String, dynamic>>[];

    final t = json['time'];
    final latVal = json['lat'];
    final lonVal = json['lon']; // change to json['lng'] if you used lng

    return DetectionSummary(
      detections: dets,
      time: t is int ? t : (t is num ? t.toInt() : null),
      lat: latVal is num ? latVal.toDouble() : null,
      lon: lonVal is num ? lonVal.toDouble() : null,
    );
  }

  Map<String, dynamic>? get best => detections.isEmpty
      ? null
      : detections.reduce((a, b) {
          final ca = (a['confidence'] is num)
              ? (a['confidence'] as num).toDouble()
              : 0.0;
          final cb = (b['confidence'] is num)
              ? (b['confidence'] as num).toDouble()
              : 0.0;
          return cb > ca ? b : a;
        });

  String? get bestCommonName => best?['common_name']?.toString();

  double? get bestConfidence {
    final c = best?['confidence'];
    return (c is num) ? c.toDouble() : null;
  }
}
