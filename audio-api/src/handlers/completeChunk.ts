import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { authenticateRequest } from '../lib/auth';
import { buildManifestKey, enforceUserPrefix } from '../lib/keys';
import { objectExists, mergeChunkIntoManifest } from '../lib/s3';
import { publishChunkUploaded } from '../lib/events';
import {
  CompleteChunkRequestSchema,
  CompleteChunkResponse,
  ChunkMetadata,
  ValidationError,
  AuthenticationError,
  NotFoundError,
} from '../lib/types';

/**
 * POST /sessions/{sessionId}/chunks/complete
 * Confirm chunk upload and merge into manifest
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
    const request = CompleteChunkRequestSchema.parse(body);

    // Verify object key matches user prefix (prevent privilege escalation)
    enforceUserPrefix(request.objectKey, user.sub);

    // Verify object exists in S3 (HEAD request)
    const exists = await objectExists(request.objectKey);
    if (!exists) {
      throw new NotFoundError(`Chunk not found in S3: ${request.objectKey}`);
    }

    // Prepare chunk metadata
    const chunk: ChunkMetadata = {
      seq: request.seq,
      key: request.objectKey,
      tStartMs: request.tStartMs,
      tEndMs: request.tEndMs,
      bytes: request.bytes,
      uploadedAt: new Date().toISOString(),
      md5: request.md5,
      sha256: request.sha256,
    };

    // Build manifest key
    const manifestKey = buildManifestKey(user.sub, sessionId);

    // Merge chunk into manifest (atomic read-modify-write)
    // Default to webm/opus if not provided in request
    const manifest = await mergeChunkIntoManifest(
      manifestKey,
      chunk,
      user.sub,
      sessionId,
      'webm/opus', // TODO: Pass codec from session metadata
      48000 // TODO: Pass sample rate from session metadata
    );

    console.log('Chunk completed:', {
      userId: user.sub,
      sessionId,
      seq: request.seq,
      manifestChunkCount: manifest.chunks.length,
    });

    // Publish event to EventBridge (optional)
    let eventId: string | undefined;
    try {
      eventId = await publishChunkUploaded(
        user.sub,
        sessionId,
        request.seq,
        request.objectKey,
        request.bytes
      );
    } catch (eventError) {
      console.warn('Failed to publish chunk uploaded event:', eventError);
      // Don't fail the request if event publishing fails
    }

    // Prepare response
    const response: CompleteChunkResponse = {
      ok: true,
      eventId,
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
    console.error('Error completing chunk:', error);

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
