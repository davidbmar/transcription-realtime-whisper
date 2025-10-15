import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { authenticateRequest } from '../lib/auth';
import { buildChunkKey } from '../lib/keys';
import { generatePresignedPutUrl } from '../lib/s3';
import {
  PresignChunkRequestSchema,
  PresignChunkResponse,
  ValidationError,
  AuthenticationError,
} from '../lib/types';

/**
 * POST /sessions/{sessionId}/chunks/presign
 * Generate presigned URL for chunk upload (single-part)
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
    const request = PresignChunkRequestSchema.parse(body);

    // Check if chunk is too large for single-part upload (>5MB)
    const MAX_SINGLE_PART = 5 * 1024 * 1024;
    if (request.sizeBytes > MAX_SINGLE_PART) {
      // TODO: Implement multipart upload variant
      return {
        statusCode: 413,
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        },
        body: JSON.stringify({
          error: `Chunk size ${request.sizeBytes} exceeds single-part limit ${MAX_SINGLE_PART}. Multipart upload not yet implemented.`,
        }),
      };
    }

    // Build S3 key with user isolation
    const objectKey = buildChunkKey(
      user.sub,
      sessionId,
      request.seq,
      request.tStartMs,
      request.tEndMs,
      request.ext
    );

    // Generate presigned PUT URL
    const putUrl = await generatePresignedPutUrl(
      objectKey,
      request.contentType,
      {
        'user-id': user.sub,
        'session-id': sessionId,
        'seq': request.seq.toString(),
      },
      300 // 5 minutes
    );

    // Prepare response
    const response: PresignChunkResponse = {
      objectKey,
      putUrl,
      headers: {
        'Content-Type': request.contentType,
        'x-amz-meta-user-id': user.sub,
        'x-amz-meta-session-id': sessionId,
        'x-amz-meta-seq': request.seq.toString(),
      },
      expiresInSeconds: 300,
    };

    console.log('Presigned URL generated:', {
      userId: user.sub,
      sessionId,
      seq: request.seq,
      objectKey,
    });

    return {
      statusCode: 200,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
      },
      body: JSON.stringify(response),
    };
  } catch (error) {
    console.error('Error generating presigned URL:', error);

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
