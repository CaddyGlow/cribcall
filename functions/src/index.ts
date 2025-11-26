import {onRequest} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";

admin.initializeApp();

interface NoiseEventPayload {
  monitorId: string;
  monitorName: string;
  timestamp: number;
  peakLevel: number;
  fcmTokens: string[];
}

interface SendResult {
  success: number;
  failure: number;
  invalidTokens: string[];
}

/**
 * Cloud Function to send FCM data messages for noise events.
 *
 * This function receives a noise event payload from a Monitor device
 * and sends high-priority FCM data messages to all specified Listener devices.
 *
 * Data messages (not notification messages) are used so the app can handle
 * the notification display even when backgrounded.
 */
export const sendNoiseEvent = onRequest(
  {region: "europe-west9"}, // Paris
  async (req, res): Promise<void> => {
    // Only allow POST
    if (req.method !== "POST") {
      res.status(405).send({error: "Method not allowed"});
      return;
    }

    // Parse payload
    const payload = req.body as NoiseEventPayload;

    // Validate required fields
    if (!payload.fcmTokens || payload.fcmTokens.length === 0) {
      res.status(400).send({error: "No FCM tokens provided"});
      return;
    }

    if (!payload.monitorId || !payload.monitorName) {
      res.status(400).send({error: "Missing monitorId or monitorName"});
      return;
    }

    if (typeof payload.timestamp !== "number" ||
        typeof payload.peakLevel !== "number") {
      res.status(400).send({error: "Invalid timestamp or peakLevel"});
      return;
    }

    // Build FCM data message
    // Using data-only messages so the app handles display (works in background)
    const message: admin.messaging.MulticastMessage = {
      tokens: payload.fcmTokens,
      data: {
        type: "NOISE_EVENT",
        monitorId: payload.monitorId,
        monitorName: payload.monitorName,
        timestamp: payload.timestamp.toString(),
        peakLevel: payload.peakLevel.toString(),
      },
      android: {
        priority: "high", // High priority for immediate delivery
        ttl: 60 * 1000, // 60 second TTL
      },
    };

    try {
      const response = await admin.messaging().sendEachForMulticast(message);

      // Collect failed tokens for cleanup
      const invalidTokens: string[] = [];
      response.responses.forEach((resp, idx) => {
        if (!resp.success) {
          const errorCode = resp.error?.code;
          // These error codes indicate the token is no longer valid
          if (
            errorCode === "messaging/registration-token-not-registered" ||
            errorCode === "messaging/invalid-registration-token"
          ) {
            invalidTokens.push(payload.fcmTokens[idx]);
          }
          console.error(
            `Failed to send to token ${idx}: ${resp.error?.message}`
          );
        }
      });

      const result: SendResult = {
        success: response.successCount,
        failure: response.failureCount,
        invalidTokens: invalidTokens,
      };

      console.log(
        `Sent noise event: success=${result.success} ` +
        `failure=${result.failure} invalid=${invalidTokens.length}`
      );

      res.status(200).send(result);
    } catch (error) {
      console.error("FCM send error:", error);
      res.status(500).send({error: "Failed to send FCM messages"});
    }
  }
);
