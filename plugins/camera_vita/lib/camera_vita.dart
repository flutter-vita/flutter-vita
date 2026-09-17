import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Point;
import 'dart:ui' as ui;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The Vita implementation of [CameraPlatform].
///
/// Non-endorsed: `camera` does not know Vita exists, so an app depends on
/// this package alongside it and calls `CameraVita.registerWith()`.
///
/// The console has two cameras, front and back, with no flash, no focus,
/// no zoom and no exposure control an app can reach; the C half
/// (`vita/camera.c`) starts one into a frame buffer and copies the frame
/// there now into a reply, as base64 RGBA, whenever asked. [buildPreview]
/// asks ten times a second and shows the frame; [takePicture] asks once and
/// writes a PNG; [onStreamedFrameAvailable] asks ten times a second and
/// hands out [CameraImageData] with one RGBA plane. Video recording is not
/// there.
///
/// Presets: [ResolutionPreset.low] is 320x240, [ResolutionPreset.medium]
/// 480x272, and everything above 640x480. A 640x480 frame is 1.2 MB, 1.6 MB
/// as base64 through the channel; a preview at that size runs at a few
/// frames a second.
class CameraVita extends CameraPlatform {
  static void registerWith() {
    CameraPlatform.instance = CameraVita();
  }

  static const MethodChannel channel =
      MethodChannel('vita/camera', JSONMethodCodec());

  final _sessions = <int, VitaCameraSession>{};

  @override
  Future<List<CameraDescription>> availableCameras() async {
    final list = await channel.invokeMethod<List<Object?>>('list');
    return [
      for (final e in list ?? const [])
        CameraDescription(
          name: (e as Map)['name'] as String,
          lensDirection: e['which'] == 0
              ? CameraLensDirection.front
              : CameraLensDirection.back,
          sensorOrientation: 0,
        ),
    ];
  }

  static int _which(CameraDescription d) =>
      d.lensDirection == CameraLensDirection.back ? 1 : 0;

  static Size _size(ResolutionPreset? preset) => switch (preset) {
        null || ResolutionPreset.low => const Size(320, 240),
        ResolutionPreset.medium => const Size(480, 272),
        _ => const Size(640, 480),
      };

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    final id = _which(cameraDescription);
    await _sessions.remove(id)?.close();
    _sessions[id] = VitaCameraSession(this, id, _size(resolutionPreset));
    return id;
  }

  VitaCameraSession _session(int id) {
    final s = _sessions[id];
    if (s == null) {
      throw PlatformException(
        code: 'state',
        message: 'camera $id: create it first',
      );
    }
    return s;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    final s = _session(cameraId);
    try {
      final r = await channel.invokeMethod<Map<Object?, Object?>>('open', {
        'which': cameraId,
        'width': s.size.width.toInt(),
        'height': s.size.height.toInt(),
      });
      s.open = true;
      s.events.add(
        CameraInitializedEvent(
          cameraId,
          (r!['width'] as int).toDouble(),
          (r['height'] as int).toDouble(),
          ExposureMode.auto,
          false,
          FocusMode.auto,
          false,
        ),
      );
    } on PlatformException catch (e) {
      s.events.add(CameraErrorEvent(cameraId, e.message ?? e.code));
      rethrow;
    }
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _session(cameraId).events.stream.whereType<CameraInitializedEvent>();

  @override
  Stream<CameraResolutionChangedEvent> onCameraResolutionChanged(
          int cameraId) =>
      _session(cameraId)
          .events
          .stream
          .whereType<CameraResolutionChangedEvent>();

  @override
  Stream<CameraClosingEvent> onCameraClosing(int cameraId) =>
      _session(cameraId).events.stream.whereType<CameraClosingEvent>();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      _session(cameraId).events.stream.whereType<CameraErrorEvent>();

  @override
  Stream<VideoRecordedEvent> onVideoRecordedEvent(int cameraId) =>
      const Stream.empty();

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      Stream.value(
        const DeviceOrientationChangedEvent(DeviceOrientation.landscapeLeft),
      );

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {}

  @override
  Future<void> unlockCaptureOrientation(int cameraId) async {}

  /// One frame, as the console has it now.
  Future<VitaFrame> frame(int cameraId) => _session(cameraId).frame();

  @override
  Future<XFile> takePicture(int cameraId) async {
    final f = await frame(cameraId);
    final image = await f.decode();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final dir = Directory.systemTemp;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final path =
        '${dir.path}/camera-$cameraId-${DateTime.now().millisecondsSinceEpoch}.png';
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return XFile(path, mimeType: 'image/png');
  }

  static Never _noVideo() => throw PlatformException(
        code: 'video',
        message:
            'camera_vita takes pictures and streams frames; it does not record video',
      );

  @override
  Future<void> prepareForVideoRecording() async {}

  @override
  Future<void> startVideoRecording(int cameraId,
          {Duration? maxVideoDuration}) =>
      _noVideo();

  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) => _noVideo();

  @override
  Future<XFile> stopVideoRecording(int cameraId) => _noVideo();

  @override
  Future<void> pauseVideoRecording(int cameraId) => _noVideo();

  @override
  Future<void> resumeVideoRecording(int cameraId) => _noVideo();

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) {
    final s = _session(cameraId);
    late final StreamController<CameraImageData> c;
    Timer? timer;
    var busy = false;
    Future<void> tick() async {
      if (busy || c.isClosed) return;
      busy = true;
      try {
        final f = await s.frame();
        if (!c.isClosed) c.add(f.toImageData());
      } catch (e) {
        if (!c.isClosed) c.addError(e);
      } finally {
        busy = false;
      }
    }

    c = StreamController<CameraImageData>(
      onListen: () => timer =
          Timer.periodic(const Duration(milliseconds: 100), (_) => tick()),
      onCancel: () => timer?.cancel(),
    );
    return c.stream;
  }

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {}

  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async {}

  @override
  Future<double> getMinExposureOffset(int cameraId) async => 0;

  @override
  Future<double> getMaxExposureOffset(int cameraId) async => 0;

  @override
  Future<double> getExposureOffsetStepSize(int cameraId) async => 0;

  @override
  Future<double> setExposureOffset(int cameraId, double offset) async => 0;

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {}

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {}

  @override
  Future<double> getMaxZoomLevel(int cameraId) async => 1;

  @override
  Future<double> getMinZoomLevel(int cameraId) async => 1;

  @override
  Future<void> setZoomLevel(int cameraId, double zoom) async {}

  @override
  Future<void> pausePreview(int cameraId) async =>
      _session(cameraId).paused = true;

  @override
  Future<void> resumePreview(int cameraId) async =>
      _session(cameraId).paused = false;

  @override
  Future<void> setDescriptionWhileRecording(CameraDescription description) =>
      _noVideo();

  @override
  Widget buildPreview(int cameraId) =>
      VitaCameraPreview(session: _session(cameraId));

  @override
  Future<void> dispose(int cameraId) async {
    await _sessions.remove(cameraId)?.close();
  }

  @override
  Future<void> setImageFileFormat(int cameraId, ImageFileFormat format) async {}
}

/// One RGBA frame from a camera.
class VitaFrame {
  VitaFrame(this.width, this.height, this.rgba, this.frame, this.fresh);

  final int width;
  final int height;
  final Uint8List rgba;

  /// The camera's own frame counter.
  final int frame;

  /// Whether the counter moved since the last frame this session read.
  final bool fresh;

  /// Mean brightness of the green channel over a coarse grid, 0..255: a
  /// covered lens reads under 10, a room in the hundreds.
  double get brightness {
    var sum = 0, n = 0;
    for (var y = 0; y < height; y += 8) {
      for (var x = 0; x < width; x += 10) {
        sum += rgba[(y * width + x) * 4 + 1];
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  Future<ui.Image> decode() {
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, width, height, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }

  CameraImageData toImageData() => CameraImageData(
        format:
            const CameraImageFormat(ImageFormatGroup.unknown, raw: 'RGBA_8888'),
        planes: [
          CameraImagePlane(
            bytes: rgba,
            bytesPerRow: width * 4,
            bytesPerPixel: 4,
            width: width,
            height: height,
          ),
        ],
        width: width,
        height: height,
      );
}

/// A created camera: its size, its events, and the frames it reads.
class VitaCameraSession {
  VitaCameraSession(this.owner, this.id, this.size);

  final CameraVita owner;
  final int id;
  final Size size;
  final events = StreamController<CameraEvent>.broadcast();
  bool open = false;
  bool paused = false;

  Future<VitaFrame> frame() async {
    final r =
        await CameraVita.channel.invokeMethod<Map<Object?, Object?>>('frame', {
      'id': id,
    });
    return VitaFrame(
      r!['width'] as int,
      r['height'] as int,
      base64Decode(r['rgba'] as String),
      r['frame'] as int,
      r['fresh'] == true,
    );
  }

  Future<void> close() async {
    if (open) {
      events.add(CameraClosingEvent(id));
      open = false;
      await CameraVita.channel.invokeMethod<void>('close', {'id': id});
    }
    // The controller left `onCameraError(id).first` waiting; a closed
    // stream would answer it with "no element", so the controller stays
    // open, as the Android implementation's does.
  }
}

/// The live picture: a frame ten times a second, drawn with [RawImage].
class VitaCameraPreview extends StatefulWidget {
  const VitaCameraPreview({super.key, required this.session});

  final VitaCameraSession session;

  @override
  State<VitaCameraPreview> createState() => _VitaCameraPreviewState();
}

class _VitaCameraPreviewState extends State<VitaCameraPreview> {
  Timer? _timer;
  ui.Image? _image;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _tick());
  }

  Future<void> _tick() async {
    if (_busy || !mounted || widget.session.paused || !widget.session.open)
      return;
    _busy = true;
    try {
      final f = await widget.session.frame();
      final img = await f.decode();
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
      });
    } catch (_) {
      // The next tick asks again; a session closing mid-frame is not news.
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) return const ColoredBox(color: Color(0xFF000000));
    return RawImage(image: img, fit: BoxFit.contain);
  }
}

extension<T> on Stream<T> {
  Stream<R> whereType<R>() => where((e) => e is R).cast<R>();
}
