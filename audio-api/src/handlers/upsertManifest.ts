import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { authenticateRequest } from '../lib/auth';
import { buildManifestKey } from '../lib/keys';
import { writeManifest } from '../lib/s3';
import {
  UpsertManifestRequestSchema,
  UpsertManifestResponse,
  SessionManifest,
  ValidationError,
  AuthenticationError,
} from '../lib/types';

/**
 * PUT /sessions/{sessionId}/manifest
 * Upsert manifest from client (optional, prefer server-side via completeChunk)
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
    const request = UpsertManifestRequestSchema.parse(body);

    // Verify session ID matches
    if (request.sessionId !== sessionId) {
      throw new ValidationError('Session ID mismatch');
    }

    // Build manifest
    const manifest: SessionManifest = {
      sessionId: request.sessionId,
      userId: user.sub,
      codec: request.codec,
      sampleRate: request.sampleRate,
      chunks: request.chunks,
      final: request.final,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      totalBytes: request.chunks.reduce((sum, c) => sum + c.bytes, 0),
      durationMs: Math.max(...request.chunks.map(c => c.tEndMs), 0),
    };

    // Build manifest key
    const manifestKey = buildManifestKey(user.sub, sessionId);

    // Write manifest to S3
    await writeManifest(manifestKey, manifest);

    console.log('Manifest upserted:', {
      userId: user.sub,
      sessionId,
      chunkCount: request.chunks.length,
      final: request.final,
    });

    // Prepare response
    const response: UpsertManifestResponse = {
      ok: true,
      manifestKey,
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
    console.error('Error upserting manifest:', error);

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
