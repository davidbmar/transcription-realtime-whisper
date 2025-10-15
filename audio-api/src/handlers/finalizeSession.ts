import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { authenticateRequest } from '../lib/auth';
import { buildManifestKey } from '../lib/keys';
import { readManifest, writeManifest } from '../lib/s3';
import { publishRecordingFinalized } from '../lib/events';
import {
  FinalizeSessionRequestSchema,
  FinalizeSessionResponse,
  ValidationError,
  AuthenticationError,
  NotFoundError,
} from '../lib/types';

/**
 * POST /sessions/{sessionId}/finalize
 * Seal manifest and emit RecordingFinalized event
 */
export async function handler(
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> {
  try {
    // Authenticate user
    const user = await authenticateRequest(event);

    // Get session ID from path parameters
    const sessionId = event.pathParameters?.sessionId;
    if (!sessionId) {
      throw new ValidationError('Missing sessionId in path');
    }

    // Parse and validate request body
    const body = event.body ? JSON.parse(event.body) : {};
    const request = FinalizeSessionRequestSchema.parse(body);

    // Build manifest key
    const manifestKey = buildManifestKey(user.sub, sessionId);

    // Read existing manifest
    const manifest = await readManifest(manifestKey);
    if (!manifest) {
      throw new NotFoundError(`Manifest not found: ${manifestKey}`);
    }

    // Update manifest with final status
    manifest.final = request.final;
    manifest.durationMs = request.durationMs;
    manifest.updatedAt = new Date().toISOString();

    // Recalculate totals
    manifest.totalBytes = manifest.chunks.reduce((sum, c) => sum + c.bytes, 0);

    // Write sealed manifest back to S3
    await writeManifest(manifestKey, manifest);

    console.log('Session finalized:', {
      userId: user.sub,
      sessionId,
      chunkCount: manifest.chunks.length,
      totalBytes: manifest.totalBytes,
      durationMs: manifest.durationMs,
    });

    // Publish RecordingFinalized event
    let eventId: string | undefined;
    try {
      eventId = await publishRecordingFinalized(
        user.sub,
        sessionId,
        manifestKey,
        manifest.chunks.length,
        manifest.totalBytes || 0,
        manifest.durationMs || 0
      );
    } catch (eventError) {
      console.warn('Failed to publish recording finalized event:', eventError);
      // Don't fail the request if event publishing fails
    }

    // Prepare response
    const response: FinalizeSessionResponse = {
      ok: true,
      manifestKey,
      chunkCount: manifest.chunks.length,
      totalBytes: manifest.totalBytes || 0,
    };

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
      body: JSON.stringify(response),
    };
  } catch (error) {
    console.error('Error finalizing session:', error);

    if (error instanceof AuthenticationError) {
      return {
        statusCode: 401,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
        body: JSON.stringify({ error: error.message }),
      };
    }

    if (error instanceof ValidationError) {
      return {
        statusCode: 400,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
        body: JSON.stringify({ error: error.message }),
      };
    }

    if (error instanceof NotFoundError) {
      return {
        statusCode: 404,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
        body: JSON.stringify({ error: error.message }),
      };
    }

    return {
      statusCode: 500,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
      body: JSON.stringify({ error: 'Internal server error' }),
    };
  }
}
