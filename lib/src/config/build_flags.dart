// Build-time feature flags and transport constants.
const bool kEnableQuic = bool.fromEnvironment(
  'CRIBCALL_ENABLE_QUIC',
  defaultValue: false,
);

const String kTransportQuic = 'quic';
const String kTransportHttpWs = 'http-ws';

const String kDefaultControlTransport = kEnableQuic
    ? kTransportQuic
    : kTransportHttpWs;
