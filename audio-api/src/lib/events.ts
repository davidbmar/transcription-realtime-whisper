import {
  EventBridgeClient,
  PutEventsCommand,
  PutEventsRequestEntry,
} from '@aws-sdk/client-eventbridge';

const REGION = process.env.REGION || 'us-east-2';
const EVENT_BUS_NAME = process.env.EVENT_BUS_NAME || 'default';
const EVENT_SOURCE = 'audio.api';

const eventBridgeClient = new EventBridgeClient({ region: REGION });

/**
 * Publish AudioChunkUploaded event
 */
export async function publishChunkUploaded(
  userId: string,
  sessionId: string,
  chunkSeq: number,
  chunkKey: string,
  bytes: number
): Promise<string> {
  const event: PutEventsRequestEntry = {
    Source: EVENT_SOURCE,
    DetailType: 'AudioChunkUploaded',
    Detail: JSON.stringify({
      userId,
      sessionId,
      chunkSeq,
      chunkKey,
      bytes,
      timestamp: new Date().toISOString(),
    }),
    EventBusName: EVENT_BUS_NAME,
  };

  const response = await eventBridgeClient.send(new PutEventsCommand({
    Entries: [event],
  }));

  if (response.FailedEntryCount && response.FailedEntryCount > 0) {
    throw new Error('Failed to publish event to EventBridge');
  }

  return response.Entries?.[0]?.EventId || 'unknown';
}

/**
 * Publish RecordingFinalized event
 */
export async function publishRecordingFinalized(
  userId: string,
  sessionId: string,
  manifestKey: string,
  chunkCount: number,
  totalBytes: number,
  durationMs: number
): Promise<string> {
  const event: PutEventsRequestEntry = {
    Source: EVENT_SOURCE,
    DetailType: 'RecordingFinalized',
    Detail: JSON.stringify({
      userId,
      sessionId,
      manifestKey,
      chunkCount,
      totalBytes,
      durationMs,
      timestamp: new Date().toISOString(),
    }),
    EventBusName: EVENT_BUS_NAME,
  };

  const response = await eventBridgeClient.send(new PutEventsCommand({
    Entries: [event],
  }));

  if (response.FailedEntryCount && response.FailedEntryCount > 0) {
    throw new Error('Failed to publish event to EventBridge');
  }

  return response.Entries?.[0]?.EventId || 'unknown';
}
