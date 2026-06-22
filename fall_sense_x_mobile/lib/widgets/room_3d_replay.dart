import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:async';
import 'room_3d_view.dart' as view;
import '../models/radar_models.dart' show formatTimestamp;

class Room3DReplay extends StatefulWidget {
  final String deviceId;
  final double roomLength;
  final double roomWidth;
  final double roomHeight;

  const Room3DReplay({
    Key? key,
    required this.deviceId,
    this.roomLength = 10.0,
    this.roomWidth = 10.0,
    this.roomHeight = 8.0,
  }) : super(key: key);

  @override
  State<Room3DReplay> createState() => _Room3DReplayState();
}

class _Room3DReplayState extends State<Room3DReplay> {
  late final DatabaseReference _framesRef;
  List<Map<String, dynamic>> _filteredFrames = [];
  int _currentFrameIndex = 0;
  bool _isPlaying = false;
  double _playbackSpeed = 1.0;
  int _selectedMinutes = 10;
  bool _isLoading = false;
  Timer? _playbackTimer;

  @override
  void initState() {
    super.initState();
    _framesRef = FirebaseDatabase.instance.ref('devices/${widget.deviceId}/frames');
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadHistoricalData(int minutes) async {
    setState(() {
      _isLoading = true;
      _isPlaying = false;
    });
    _playbackTimer?.cancel();

    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Stored as seconds-since-epoch (see firmware's firebase_enqueue_frame),
      // so the cutoff for the orderByChild query must also be in seconds.
      final cutoffSeconds = (now ~/ 1000) - (minutes * 60);

      // Query server-side instead of fetching every frame and filtering
      // client-side - this node can hold up to 100 frames per device and
      // will only grow with more devices/history.
      final snapshot = await _framesRef
          .orderByChild('timestamp')
          .startAt(cutoffSeconds)
          .get();
      List<Map<String, dynamic>> frames = [];

      if (snapshot.value != null && snapshot.value is Map) {
        final data = snapshot.value as Map;
        data.forEach((key, value) {
          if (value is Map) {
            Map<String, dynamic> frame = {};
            value.forEach((k, v) {
              frame[k.toString()] = v;
            });
            frame['id'] = key.toString();
            frames.add(frame);
          }
        });

        // Sort frames by timestamp
        frames.sort((a, b) {
          final aTime = (a['timestamp'] as num?)?.toInt() ?? (a['timestamp_ms'] as num?)?.toInt() ?? 0;
          final bTime = (b['timestamp'] as num?)?.toInt() ?? (b['timestamp_ms'] as num?)?.toInt() ?? 0;
          return aTime.compareTo(bTime);
        });
      }

      setState(() {
        _filteredFrames = frames;
        _currentFrameIndex = 0;
        _isLoading = false;
      });

      debugPrint('Loaded ${frames.length} frames from last $minutes minutes');
    } catch (e) {
      debugPrint('Error loading historical data: $e');
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading data: $e')),
        );
      }
    }
  }

  void _startPlayback() {
    if (_filteredFrames.isEmpty) return;

    setState(() {
      _isPlaying = true;
    });

    _playbackTimer = Timer.periodic(
      Duration(milliseconds: (1000 / _playbackSpeed).toInt()),
      (timer) {
        if (!_isPlaying) {
          timer.cancel();
          return;
        }

        setState(() {
          _currentFrameIndex++;
          if (_currentFrameIndex >= _filteredFrames.length) {
            _currentFrameIndex = 0;
            _isPlaying = false;
            timer.cancel();
          }
        });
      },
    );
  }

  void _pausePlayback() {
    _playbackTimer?.cancel();
    setState(() {
      _isPlaying = false;
    });
  }

  void _resetPlayback() {
    _playbackTimer?.cancel();
    setState(() {
      _currentFrameIndex = 0;
      _isPlaying = false;
    });
  }

  void _showTimeRangeDialog() {
    final tempController = TextEditingController(text: _selectedMinutes.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Time Range'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Load data from the last X minutes:'),
            const SizedBox(height: 12),
            TextField(
              controller: tempController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Minutes',
                hintText: '10',
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [5, 10, 15, 30, 60].map((minutes) {
                return ChoiceChip(
                  label: Text('$minutes min'),
                  selected: _selectedMinutes == minutes,
                  onSelected: (selected) {
                    tempController.text = minutes.toString();
                  },
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final minutes = int.tryParse(tempController.text) ?? _selectedMinutes;
              if (minutes > 0) {
                setState(() {
                  _selectedMinutes = minutes;
                });
                _loadHistoricalData(minutes);
                Navigator.pop(context);
              }
            },
            child: const Text('Load'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Room View Replay'),
        backgroundColor: Colors.grey[900],
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showTimeRangeDialog,
            tooltip: 'Set Time Range',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(),
            )
          : _filteredFrames.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.inbox, size: 80, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text(
                        'No data available',
                        style: TextStyle(color: Colors.white, fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Load data from the last $_selectedMinutes minutes',
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _showTimeRangeDialog,
                        icon: const Icon(Icons.download),
                        label: const Text('Load Data'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Control Panel
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withOpacity(0.4)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _currentFrameIndex < _filteredFrames.length
                                    ? formatTimestamp(
                                        _filteredFrames[_currentFrameIndex]['timestamp'] ??
                                            _filteredFrames[_currentFrameIndex]['timestamp_ms'])
                                    : '--',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                'Frame ${_currentFrameIndex + 1} of ${_filteredFrames.length}',
                                style: TextStyle(color: Colors.grey[400], fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Playback Controls
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.skip_previous),
                                color: Colors.white,
                                onPressed: _resetPlayback,
                                tooltip: 'Reset',
                              ),
                              IconButton(
                                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                                color: Colors.white,
                                onPressed: _isPlaying ? _pausePlayback : _startPlayback,
                                tooltip: _isPlaying ? 'Pause' : 'Play',
                              ),
                              Expanded(
                                child: Slider(
                                  value: _currentFrameIndex.toDouble(),
                                  min: 0,
                                  max: _filteredFrames.isEmpty
                                      ? 1
                                      : (_filteredFrames.length - 1).toDouble(),
                                  onChanged: (value) {
                                    _pausePlayback();
                                    setState(() {
                                      _currentFrameIndex = value.toInt();
                                    });
                                  },
                                  activeColor: Colors.orange,
                                ),
                              ),
                            ],
                          ),
                          // Speed Control
                          Row(
                            children: [
                              const Text(
                                'Speed:',
                                style: TextStyle(color: Colors.white, fontSize: 12),
                              ),
                              Expanded(
                                child: Slider(
                                  value: _playbackSpeed,
                                  min: 0.25,
                                  max: 4.0,
                                  divisions: 15,
                                  onChanged: (value) {
                                    setState(() {
                                      _playbackSpeed = value;
                                    });
                                    if (_isPlaying) {
                                      _pausePlayback();
                                      _startPlayback();
                                    }
                                  },
                                  activeColor: Colors.cyan,
                                ),
                              ),
                              Text(
                                '${_playbackSpeed.toStringAsFixed(2)}x',
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Room View
                    Expanded(
                      child: view.Room3DView(
                        frames: [
                          if (_currentFrameIndex < _filteredFrames.length)
                            _filteredFrames[_currentFrameIndex]
                        ],
                        roomLength: widget.roomLength,
                        roomWidth: widget.roomWidth,
                        roomHeight: widget.roomHeight,
                      ),
                    ),
                  ],
                ),
    );
  }
}
