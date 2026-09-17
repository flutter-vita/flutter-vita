import 'package:device_info_plus/device_info_plus.dart';
import 'package:device_info_plus_platform_interface/device_info_plus_platform_interface.dart';
import 'package:flutter/services.dart';

/// The Vita implementation of [DeviceInfoPlatform].
///
/// Non-endorsed: `device_info_plus` does not know Vita exists, so an app
/// depends on this package alongside it and calls
/// `DeviceInfoPlusVita.registerWith()`.
///
/// `Platform.isLinux` is true on the console (the Dart VM is built as a
/// Linux target), so `DeviceInfoPlugin().deviceInfo` goes through
/// `linuxInfo` and casts to [LinuxDeviceInfo]. [VitaDeviceInfo] is one, with
/// the console's facts in its fields and more in [VitaDeviceInfo.data].
class DeviceInfoPlusVita extends DeviceInfoPlatform {
  static void registerWith() {
    DeviceInfoPlatform.instance = DeviceInfoPlusVita();
  }

  static const MethodChannel _channel =
      MethodChannel('vita/device', JSONMethodCodec());

  @override
  Future<BaseDeviceInfo> deviceInfo() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('info');
    return VitaDeviceInfo.fromMap(r!.cast<String, Object?>());
  }
}

/// What the console says about itself, in [LinuxDeviceInfo]'s shape so the
/// `linuxInfo` route works: `name` is "PlayStation Vita" or "PlayStation
/// TV", `version` and `versionId` the firmware ("3.73"), `id` "vita",
/// `prettyName` both together, `machineId` the running title's id.
///
/// [data] adds `model_code` (the kernel's number, 0x10000 Vita, 0x20000
/// PS TV), `title_id`, `cores` (4), `arm_mhz`, `bus_mhz`, `gpu_mhz` (the
/// clocks now).
class VitaDeviceInfo extends LinuxDeviceInfo {
  VitaDeviceInfo._(this.vita)
      : super(
          name: vita['model'] as String,
          version: vita['firmware'] as String,
          versionId: vita['firmware'] as String,
          id: 'vita',
          prettyName: '${vita['model']} ${vita['firmware']}',
          machineId: vita['title_id'] as String,
        );

  factory VitaDeviceInfo.fromMap(Map<String, Object?> m) => VitaDeviceInfo._(m);

  /// The channel's answer as it came.
  final Map<String, Object?> vita;

  String get model => vita['model'] as String;
  String get firmware => vita['firmware'] as String;
  String get titleId => vita['title_id'] as String;
  bool get isPlayStationTv => vita['model_code'] == 0x20000;
  int get armMhz => vita['arm_mhz'] as int;
  int get busMhz => vita['bus_mhz'] as int;
  int get gpuMhz => vita['gpu_mhz'] as int;

  @override
  Map<String, dynamic> get data => {...super.data, ...vita};
}
