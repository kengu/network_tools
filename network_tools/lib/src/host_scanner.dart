import 'dart:async';
import 'dart:math';

import 'package:dart_ping/dart_ping.dart';
import 'package:isolate_manager/isolate_manager.dart';
import 'package:network_tools/src/models/active_host.dart';
import 'package:network_tools/src/models/callbacks.dart';
import 'package:network_tools/src/models/sendable_active_host.dart';
import 'package:network_tools/src/network_tools_utils.dart';
import 'package:network_tools/src/port_scanner.dart';

/// Scans for all hosts in a subnet.
class HostScanner {
  /// Devices scan will start from this integer Id
  static const int defaultFirstHostId = 1;

  /// Devices scan will stop at this integer id
  static const int defaultLastHostId = 254;

  /// Scans for all hosts in a particular subnet (e.g., 192.168.1.0/24)
  /// Set maxHost to higher value if you are not getting results.
  /// It won't firstHostId again unless previous scan is completed due to heavy
  /// resource consumption.
  /// [resultsInAddressAscendingOrder] = false will return results faster but not in
  /// ascending order and without [progressCallback].
  static Stream<SendableActivateHost> _getAllSendablePingableDevices(
    String subnet, {
    int firstHostId = defaultFirstHostId,
    int lastHostId = defaultLastHostId,
    int timeoutInSeconds = 1,
    ProgressCallback? progressCallback,
    bool resultsInAddressAscendingOrder = true,
  }) async* {
    final int lastValidSubnet =
        validateAndGetLastValidSubnet(subnet, firstHostId, lastHostId);
    final List<Future<SendableActivateHost?>> activeHostsFuture = [];
    final StreamController<SendableActivateHost> activeHostsController =
        StreamController<SendableActivateHost>();

    for (int i = firstHostId; i <= lastValidSubnet; i++) {
      activeHostsFuture.add(
        _getHostFromPing(
          activeHostsController: activeHostsController,
          host: '$subnet.$i',
          i: i,
          timeoutInSeconds: timeoutInSeconds,
        ),
      );
    }

    if (!resultsInAddressAscendingOrder) {
      yield* activeHostsController.stream;
    }

    int i = 0;
    for (final Future<SendableActivateHost?> host in activeHostsFuture) {
      i++;
      final SendableActivateHost? tempHost = await host;

      progressCallback
          ?.call((i - firstHostId) * 100 / (lastValidSubnet - firstHostId));

      if (tempHost == null) {
        continue;
      }
      yield tempHost;
    }
  }

  static Stream<ActiveHost> getAllPingableDevices(
    String subnet, {
    int firstHostId = defaultFirstHostId,
    int lastHostId = defaultLastHostId,
    int timeoutInSeconds = 1,
    ProgressCallback? progressCallback,
    bool resultsInAddressAscendingOrder = true,
  }) async* {
    final stream = _getAllSendablePingableDevices(subnet, firstHostId: firstHostId, lastHostId: lastHostId, 
   timeoutInSeconds: timeoutInSeconds, progressCallback: progressCallback, resultsInAddressAscendingOrder: resultsInAddressAscendingOrder);
   await for (final sendableActivateHost in stream){
    final activeHost = ActiveHost.fromSendableActiveHost(sendableActivateHost: sendableActivateHost);

    await activeHost.resolveInfo();
         
    yield activeHost; 
   }
  }

  static Future<SendableActivateHost?> _getHostFromPing({
    required String host,
    required int i,
    required StreamController<SendableActivateHost> activeHostsController,
    int timeoutInSeconds = 1,
  }) async {
    await for (final PingData pingData
        in Ping(host, count: 1, timeout: timeoutInSeconds).stream) {
      final PingResponse? response = pingData.response;
      if (response != null) {
        final Duration? time = response.time;
        if (time != null) {
          final tempSendableActivateHost = SendableActivateHost(host, pingData);
          activeHostsController.add(tempSendableActivateHost);
          return tempSendableActivateHost;
        }
      }
    }
    return null;
  }

  static int validateAndGetLastValidSubnet(
    String subnet,
    int firstHostId,
    int lastHostId,
  ) {
    final int maxEnd = maxHost;
    if (firstHostId > lastHostId ||
        firstHostId < defaultFirstHostId ||
        lastHostId < defaultFirstHostId ||
        firstHostId > maxEnd ||
        lastHostId > maxEnd) {
      throw 'Invalid subnet range or firstHostId < lastHostId is not true';
    }
    return min(lastHostId, maxEnd);
  }

  /// Works same as [getAllPingableDevices] but does everything inside
  /// isolate out of the box.
  static Stream<ActiveHost> getAllPingableDevicesAsync(
    String subnet, {
    int firstHostId = defaultFirstHostId,
    int lastHostId = defaultLastHostId,
    int timeoutInSeconds = 1,
    ProgressCallback? progressCallback,
    bool resultsInAddressAscendingOrder = true,
  }) async* {

    const int scanRangeForIsolate = 51;
    final int lastValidSubnet =
        validateAndGetLastValidSubnet(subnet, firstHostId, lastHostId);
    for (int i = firstHostId;
        i <= lastValidSubnet;
        i += scanRangeForIsolate + 1) {
      final isolateManager =
          IsolateManager.createOwnIsolate(_startSearchingDevices);
      final limit = min(i + scanRangeForIsolate, lastValidSubnet);
      log.fine('Scanning from $i to $limit');
      isolateManager.sendMessage(<String>[
        subnet,
        i.toString(),
        limit.toString(),
        timeoutInSeconds.toString(),
        resultsInAddressAscendingOrder.toString(),
      ]);
      await for (final message in  isolateManager.onMessage.asBroadcastStream()){
        if (message is SendableActivateHost) {
          progressCallback
              ?.call((i - firstHostId) * 100 / (lastValidSubnet - firstHostId));
          
         final activeHostFound = ActiveHost.fromSendableActiveHost(sendableActivateHost: message);
         await activeHostFound.resolveInfo(); 
         yield activeHostFound;
        } else if (message is String && message == 'Done') {
          isolateManager.stop();
        }
      } 
    }
  }

  /// Will search devices in the network inside new isolate
  @pragma('vm:entry-point')
  static Future<void> _startSearchingDevices(dynamic params) async {
    final channel = IsolateManagerController(params);
    channel.onIsolateMessage.listen((message) async {
      List<String> paramsListString = [];
      if (message is List<String>) {
        paramsListString = message;
      } else {
        return;
      }

      final String subnetIsolate = paramsListString[0];
      final int firstSubnetIsolate = int.parse(paramsListString[1]);
      final int lastSubnetIsolate = int.parse(paramsListString[2]);
      final int timeoutInSeconds = int.parse(paramsListString[3]);
      final bool resultsInAddressAscendingOrder = paramsListString[4] == "true";

      /// Will contain all the hosts that got discovered in the network, will
      /// be use inorder to cancel on dispose of the page.
      final Stream<SendableActivateHost> hostsDiscoveredInNetwork =
          HostScanner._getAllSendablePingableDevices(
        subnetIsolate,
        firstHostId: firstSubnetIsolate,
        lastHostId: lastSubnetIsolate,
        timeoutInSeconds: timeoutInSeconds,
        resultsInAddressAscendingOrder: resultsInAddressAscendingOrder,
      );

      await for (final SendableActivateHost activeHostFound in hostsDiscoveredInNetwork) {
        channel.sendResult(activeHostFound);
      }
      channel.sendResult('Done');
    });
  }

  /// Scans for all hosts that have the specific port that was given.
  /// [resultsInAddressAscendingOrder] = false will return results faster but not in
  /// ascending order and without [progressCallback].
  static Stream<ActiveHost> scanDevicesForSinglePort(
    String subnet,
    int port, {
    int firstHostId = defaultFirstHostId,
    int lastHostId = defaultLastHostId,
    Duration timeout = const Duration(milliseconds: 2000),
    ProgressCallback? progressCallback,
    bool resultsInAddressAscendingOrder = true,
  }) async* {
    final int lastValidSubnet =
        validateAndGetLastValidSubnet(subnet, firstHostId, lastHostId);
    final List<Future<ActiveHost?>> activeHostOpenPortList = [];
    final StreamController<ActiveHost> activeHostsController =
        StreamController<ActiveHost>();

    for (int i = firstHostId; i <= lastValidSubnet; i++) {
      final host = '$subnet.$i';
      activeHostOpenPortList.add(
        PortScanner.connectToPort(
          address: host,
          port: port,
          timeout: timeout,
          activeHostsController: activeHostsController,
        ),
      );
    }

    if (!resultsInAddressAscendingOrder) {
      yield* activeHostsController.stream;
    }

    int counter = firstHostId;
    for (final Future<ActiveHost?> openPortActiveHostFuture
        in activeHostOpenPortList) {
      final ActiveHost? activeHost = await openPortActiveHostFuture;
      if (activeHost != null) {
        yield activeHost;
      }
      progressCallback?.call(
        (counter - firstHostId) * 100 / (lastValidSubnet - firstHostId),
      );
      counter++;
    }
  }

  /// Defines total number of subnets in class A network
  static const classASubnets = 16777216;

  /// Defines total number of subnets in class B network
  static const classBSubnets = 65536;

  /// Defines total number of subnets in class C network
  static const classCSubnets = 256;

  /// Minimum value of first octet in IPv4 address used by getMaxHost
  static const int minNetworkId = 1;

  /// Maximum value of first octect in IPv4 address used by getMaxHost
  static const int maxNetworkId = 223;

  /// returns the max number of hosts a subnet can have excluding network Id and broadcast Id
  @Deprecated(
    "Implementation is wrong, since we only append in last octet, max host can only be 254. Use maxHost getter",
  )
  static int getMaxHost(String subnet) {
    if (subnet.isEmpty) {
      throw ArgumentError('Invalid subnet address, address can not be empty.');
    }
    final List<String> firstOctetStr = subnet.split('.');
    if (firstOctetStr.isEmpty) {
      throw ArgumentError(
        'Invalid subnet address, address should be in IPv4 format x.x.x',
      );
    }

    final int firstOctet = int.parse(firstOctetStr[0]);

    if (firstOctet >= minNetworkId && firstOctet < 128) {
      return classASubnets;
    } else if (firstOctet >= 128 && firstOctet < 192) {
      return classBSubnets;
    } else if (firstOctet >= 192 && firstOctet <= maxNetworkId) {
      return classCSubnets;
    }
    // Out of range for first octet
    throw RangeError.range(
      firstOctet,
      minNetworkId,
      maxNetworkId,
      'subnet',
      'Out of range for first octet',
    );
  }

  static int get maxHost => defaultLastHostId;
}
