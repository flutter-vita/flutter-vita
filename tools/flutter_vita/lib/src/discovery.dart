import 'dart:async';
import 'dart:io';

import 'device.dart';

/// Find Vitas by sweeping the local subnet.
///
/// A broadcast responder in the dev server would be tidier, but it would also
/// mean every already-deployed app is undiscoverable until it is rebuilt. A
/// TCP sweep needs no change on the device, so it works against what is
/// running right now — including the loader, which is what you have after a
/// crash and exactly when you want to find the thing.
///
/// 254 hosts times two ports, in windows of 16, against a 1.5 s connect
/// timeout. The timeout is set for wifi rather than ethernet: a Vita on a
/// congested link has answered in over 500 ms, and round trips on this one
/// have been measured above a second.
Future<List<VitaDevice>> discover({
  String? subnet,
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final prefix = subnet ?? await localSubnet();
  if (prefix == null) {
    return const [];
  }

  // Bounded concurrency, and the bound is not politeness.
  //
  // The dev server calls sceNetListen(srv, 2) -- a backlog of two. Firing 508
  // connects at once means almost all of them are dropped, including the one
  // that would have found the device: the first sweep written that way missed
  // a Vita that answered a manual ping a second later. A small window also
  // keeps the sweep from disturbing an app that is mid-frame.
  const inFlight = 16;
  final found = <VitaDevice>[];
  final queue = <({String host, VitaRole role})>[
    for (var h = 1; h < 255; h++)
      for (final role in VitaRole.values) (host: '$prefix.$h', role: role),
  ];

  for (var i = 0; i < queue.length; i += inFlight) {
    final batch = queue.skip(i).take(inFlight);
    final results = await Future.wait(
      batch.map((p) => VitaDevice.probe(p.host, p.role, timeout: timeout)),
    );
    found.addAll(results.whereType<VitaDevice>());
  }
  return found;
}

/// The /24 this machine is on, as "192.168.0".
///
/// Loopback and link-local are skipped. If several interfaces qualify — wifi
/// and a wired dock, say — this takes the first, which is a guess; `--subnet`
/// exists for when the guess is wrong.
Future<String?> localSubnet() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      final parts = address.address.split('.');
      if (parts.length == 4) {
        return parts.take(3).join('.');
      }
    }
  }
  return null;
}
