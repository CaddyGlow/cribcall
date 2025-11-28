// Build-time transport constants.
const int kControlDefaultPort = 48080;
const int kPairingDefaultPort = 48081;
const String kTransportHttpWs = 'http-ws';

const String kDefaultControlTransport = kTransportHttpWs;

// FCM Cloud Function URL - configure per environment.
// Override at build time with: --dart-define=FCM_FUNCTION_URL=https://...
const String kFcmCloudFunctionUrl = String.fromEnvironment(
  'FCM_FUNCTION_URL',
  // defaultValue: 'https://europe-west9-cribcall-3a8e0.cloudfunctions.net/sendNoiseEvent',
  defaultValue: 'https://sendnoiseevent-iba4u4beoa-od.a.run.app',
);

// FCM notification channel ID for Android.
const String kFcmNotificationChannelId = 'cribcall_alerts';
