// ignore_for_file: library_private_types_in_public_api

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const String _libName = 'cribcall_quic';

class CribcallQuic {
  CribcallQuic({DynamicLibrary? dynamicLibrary})
    : _bindings = _NativeBindings(dynamicLibrary ?? _loadLibrary()) {
    _initDartApi();
  }

  final _NativeBindings _bindings;
  bool _initialized = false;

  void _initDartApi() {
    if (_initialized) return;
    _throwIfError(
      _bindings.initDartApi(NativeApi.postCObject.cast()),
      'init_dart_api',
    );
    _initialized = true;
  }

  void initLogging() {
    _throwIfError(_bindings.initLogging(), 'init logging');
  }

  String version() {
    final ptr = _bindings.version();
    return ptr.cast<Utf8>().toDartString();
  }

  QuicConfigHandle createConfig() {
    final configPtrPtr = calloc<Pointer<CcQuicConfig>>();
    final status = _bindings.configNew(configPtrPtr);
    _throwIfError(status, 'config init');
    final handle = configPtrPtr.value;
    calloc.free(configPtrPtr);
    final isNullHandle = handle == Pointer<CcQuicConfig>.fromAddress(0);
    if (isNullHandle) {
      _throwIfError(CcQuicStatus.internal.code, 'config allocation');
    }
    return QuicConfigHandle._(handle, _bindings);
  }

  Future<QuicNativeConnection> startClient({
    required QuicConfigHandle config,
    required String host,
    required int port,
    required String serverName,
    required String expectedServerFingerprint,
    required String certPemPath,
    required String keyPemPath,
  }) async {
    final portStream = ReceivePort();
    final handlePtr = calloc<Uint64>();
    final hostPtr = host.toNativeUtf8();
    final serverPtr = serverName.toNativeUtf8();
    final expectedPtr = expectedServerFingerprint.toNativeUtf8();
    final certPtr = certPemPath.toNativeUtf8();
    final keyPtr = keyPemPath.toNativeUtf8();
    final status = _bindings.clientConnect(
      config.take(),
      hostPtr,
      port,
      serverPtr,
      expectedPtr,
      certPtr,
      keyPtr,
      portStream.sendPort.nativePort,
      handlePtr,
    );
    final handle = handlePtr.value;
    calloc.free(handlePtr);
    calloc
      ..free(hostPtr)
      ..free(serverPtr)
      ..free(expectedPtr)
      ..free(certPtr)
      ..free(keyPtr);
    if (status != CcQuicStatus.ok.code) {
      portStream.close();
      _throwIfError(status, 'client_connect');
    }
    final controller = StreamController<QuicEvent>.broadcast();
    late StreamSubscription sub;
    void cleanup() {
      sub.cancel();
      portStream.close();
      controller.close();
    }

    sub = portStream.listen((dynamic message) {
      if (message is String) {
        final event = QuicEvent.fromJson(message);
        controller.add(event);
        if (event is QuicClosed || event is QuicError) {
          cleanup();
        }
      }
    });
    return QuicNativeConnection(
      handle: handle,
      events: controller.stream,
      port: portStream,
      bindings: _bindings,
      onDispose: cleanup,
    );
  }

  Future<QuicNativeConnection> startServer({
    required QuicConfigHandle config,
    required String bindAddress,
    required int port,
    required String certPemPath,
    required String keyPemPath,
    List<String> trustedFingerprints = const [],
  }) async {
    final portStream = ReceivePort();
    final handlePtr = calloc<Uint64>();
    final bindPtr = bindAddress.toNativeUtf8();
    final certPtr = certPemPath.toNativeUtf8();
    final keyPtr = keyPemPath.toNativeUtf8();
    final trustedPtr = trustedFingerprints.join(',').toNativeUtf8();
    final status = _bindings.serverStart(
      config.take(),
      bindPtr,
      port,
      certPtr,
      keyPtr,
      trustedPtr,
      portStream.sendPort.nativePort,
      handlePtr,
    );
    final handle = handlePtr.value;
    calloc.free(handlePtr);
    calloc
      ..free(bindPtr)
      ..free(certPtr)
      ..free(keyPtr)
      ..free(trustedPtr);
    if (status != CcQuicStatus.ok.code) {
      portStream.close();
      _throwIfError(status, 'server_start');
    }
    final controller = StreamController<QuicEvent>.broadcast();
    late StreamSubscription sub;
    void cleanup() {
      sub.cancel();
      portStream.close();
      controller.close();
    }

    sub = portStream.listen((dynamic message) {
      if (message is String) {
        final event = QuicEvent.fromJson(message);
        controller.add(event);
        if (event is QuicClosed || event is QuicError) {
          cleanup();
        }
      }
    });
    return QuicNativeConnection(
      handle: handle,
      events: controller.stream,
      port: portStream,
      bindings: _bindings,
      onDispose: cleanup,
    );
  }
}

class QuicNativeConnection {
  QuicNativeConnection({
    required this.handle,
    required Stream<QuicEvent> events,
    required this.port,
    required this.bindings,
    required this.onDispose,
  }) {
    _subscription = events.listen((event) {
      _trackEvent(event);
      _controller.add(event);
    });
  }

  final int handle;
  final ReceivePort port;
  final _NativeBindings bindings;
  final void Function() onDispose;
  final _controller = StreamController<QuicEvent>.broadcast();
  Stream<QuicEvent> get events => _controller.stream;
  final Set<String> _connectionIds = {};
  String? _lastConnectionId;
  StreamSubscription<QuicEvent>? _subscription;

  void _trackEvent(QuicEvent event) {
    final id = event.connectionId;
    if (id != null) {
      _connectionIds.add(id);
      _lastConnectionId ??= id;
      if (event is QuicClosed) {
        _connectionIds.remove(id);
        if (_lastConnectionId == id) {
          _lastConnectionId = _connectionIds.isNotEmpty
              ? _connectionIds.first
              : null;
        }
      }
    }
  }

  void send(Uint8List data, {String? connectionId}) {
    final targetId = connectionId ?? _lastConnectionId;
    if (targetId == null) {
      throw StateError('No connection available for send');
    }
    final connBytes = utf8.encode(targetId);
    final connPtr = calloc<Uint8>(connBytes.length);
    connPtr.asTypedList(connBytes.length).setAll(0, connBytes);
    final dataPtr = calloc<Uint8>(data.length);
    dataPtr.asTypedList(data.length).setAll(0, data);
    bindings.send(handle, connPtr, connBytes.length, dataPtr, data.length);
    calloc.free(connPtr);
    calloc.free(dataPtr);
  }

  void close() {
    bindings.close(handle);
    port.close();
    _subscription?.cancel();
    _controller.close();
    onDispose();
  }
}

class QuicConfigHandle {
  QuicConfigHandle._(this._pointer, this._bindings);

  Pointer<CcQuicConfig>? _pointer;
  final _NativeBindings _bindings;

  Pointer<CcQuicConfig> take() {
    final ptr = _pointer;
    if (ptr == null) {
      throw StateError('Config already consumed or freed');
    }
    _pointer = null;
    return ptr;
  }

  void dispose() {
    final ptr = _pointer;
    if (ptr != null) {
      _bindings.configFree(ptr);
      _pointer = null;
    }
  }
}

abstract class QuicEvent {
  const QuicEvent({this.connectionId});

  final String? connectionId;

  factory QuicEvent.fromJson(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final connId = map['connection_id'] as String?;
    switch (map['type'] as String) {
      case 'connected':
        return QuicConnected(
          handle: map['handle'] as int,
          connectionId: connId,
          peerFingerprint: map['peer_fingerprint'] as String? ?? '',
        );
      case 'message':
        return QuicMessage(
          handle: map['handle'] as int,
          connectionId: connId,
          data: base64Decode(map['data_base64'] as String),
        );
      case 'closed':
        return QuicClosed(
          handle: map['handle'] as int,
          connectionId: connId,
          reason: map['reason'] as String?,
        );
      case 'error':
      default:
        return QuicError(
          handle: map['handle'] as int? ?? 0,
          connectionId: connId,
          message: map['message'] as String? ?? 'unknown error',
        );
    }
  }
}

class QuicConnected extends QuicEvent {
  const QuicConnected({
    required this.handle,
    required this.peerFingerprint,
    String? connectionId,
  }) : super(connectionId: connectionId);

  final int handle;
  final String peerFingerprint;
}

class QuicMessage extends QuicEvent {
  const QuicMessage({
    required this.handle,
    required this.data,
    String? connectionId,
  }) : super(connectionId: connectionId);

  final int handle;
  final Uint8List data;
}

class QuicClosed extends QuicEvent {
  const QuicClosed({required this.handle, this.reason, String? connectionId})
    : super(connectionId: connectionId);

  final int handle;
  final String? reason;
}

class QuicError extends QuicEvent {
  const QuicError({
    required this.handle,
    required this.message,
    String? connectionId,
  }) : super(connectionId: connectionId);

  final int handle;
  final String message;
}

class CcQuicStatus {
  const CcQuicStatus._(this.code, this.label);

  final int code;
  final String label;

  static const ok = CcQuicStatus._(0, 'ok');
  static const nullPointer = CcQuicStatus._(1, 'null_pointer');
  static const configError = CcQuicStatus._(2, 'config_error');
  static const invalidAlpn = CcQuicStatus._(3, 'invalid_alpn');
  static const certLoadError = CcQuicStatus._(4, 'cert_load_error');
  static const socketError = CcQuicStatus._(5, 'socket_error');
  static const handshakeError = CcQuicStatus._(6, 'handshake_error');
  static const eventSendError = CcQuicStatus._(7, 'event_send_error');
  static const internal = CcQuicStatus._(255, 'internal');

  static const values = [
    ok,
    nullPointer,
    configError,
    invalidAlpn,
    certLoadError,
    socketError,
    handshakeError,
    eventSendError,
    internal,
  ];

  static CcQuicStatus fromCode(int code) => values.firstWhere(
    (status) => status.code == code,
    orElse: () => internal,
  );
}

class CribcallQuicException implements Exception {
  CribcallQuicException(this.operation, this.status);

  final String operation;
  final CcQuicStatus status;

  @override
  String toString() =>
      'CribcallQuicException($operation failed with ${status.label} [${status.code}])';
}

void _throwIfError(int status, String op) {
  final parsed = CcQuicStatus.fromCode(status);
  if (parsed != CcQuicStatus.ok) {
    throw CribcallQuicException(op, parsed);
  }
}

DynamicLibrary _loadLibrary() {
  if (Platform.isMacOS || Platform.isIOS) {
    // Cargokit builds a staticlib on Darwin and links it into the process, so
    // prefer the process/executable handle; fall back to bundled frameworks for
    // any dynamic builds.
    try {
      return DynamicLibrary.process();
    } on ArgumentError {
      try {
        return DynamicLibrary.executable();
      } on ArgumentError {
        try {
          return DynamicLibrary.open('$_libName.framework/$_libName');
        } on ArgumentError {
          return DynamicLibrary.open('lib$_libName.dylib');
        }
      }
    }
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isLinux) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      'lib$_libName.so',
      '$exeDir/lib/lib$_libName.so',
    ];
    for (final path in candidates) {
      try {
        return DynamicLibrary.open(path);
      } on ArgumentError {
        // Try next path.
      }
    }
    throw ArgumentError(
      'Could not load lib$_libName.so (tried: ${candidates.join(', ')})',
    );
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

class _NativeBindings {
  _NativeBindings(DynamicLibrary lib)
    : initDartApi = lib
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('cc_quic_init_dart_api'),
      initLogging = lib.lookupFunction<Int32 Function(), int Function()>(
        'cc_quic_init_logging',
      ),
      version = lib
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'cc_quic_version',
          ),
      configNew = lib
          .lookupFunction<
            Int32 Function(Pointer<Pointer<CcQuicConfig>>),
            int Function(Pointer<Pointer<CcQuicConfig>>)
          >('cc_quic_config_new'),
      configFree = lib
          .lookupFunction<
            Void Function(Pointer<CcQuicConfig>),
            void Function(Pointer<CcQuicConfig>)
          >('cc_quic_config_free'),
      clientConnect = lib
          .lookupFunction<
            Int32 Function(
              Pointer<CcQuicConfig>,
              Pointer<Utf8>,
              Uint16,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Int64,
              Pointer<Uint64>,
            ),
            int Function(
              Pointer<CcQuicConfig>,
              Pointer<Utf8>,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
              Pointer<Uint64>,
            )
          >('cc_quic_client_connect'),
      serverStart = lib
          .lookupFunction<
            Int32 Function(
              Pointer<CcQuicConfig>,
              Pointer<Utf8>,
              Uint16,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Int64,
              Pointer<Uint64>,
            ),
            int Function(
              Pointer<CcQuicConfig>,
              Pointer<Utf8>,
              int,
              Pointer<Utf8>,
              Pointer<Utf8>,
              Pointer<Utf8>,
              int,
              Pointer<Uint64>,
            )
          >('cc_quic_server_start'),
      send = lib
          .lookupFunction<
            Int32 Function(
              Uint64,
              Pointer<Uint8>,
              IntPtr,
              Pointer<Uint8>,
              IntPtr,
            ),
            int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int)
          >('cc_quic_conn_send'),
      close = lib.lookupFunction<Int32 Function(Uint64), int Function(int)>(
        'cc_quic_conn_close',
      );

  final int Function(Pointer<Void>) initDartApi;
  final int Function() initLogging;
  final Pointer<Utf8> Function() version;
  final int Function(Pointer<Pointer<CcQuicConfig>>) configNew;
  final void Function(Pointer<CcQuicConfig>) configFree;
  final int Function(
    Pointer<CcQuicConfig>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Uint64>,
  )
  clientConnect;
  final int Function(
    Pointer<CcQuicConfig>,
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    Pointer<Uint64>,
  )
  serverStart;
  final int Function(
    int,
    Pointer<Uint8>,
    int,
    Pointer<Uint8>,
    int,
  ) send;
  final int Function(int) close;
}

final class CcQuicConfig extends Opaque {}
