import { APIGatewayProxyEvent, APIGatewayProxyResult } from 'aws-lambda';
import { v4 as uuidv4 } from 'uuid';
import { authenticateRequest } from '../lib/auth';
import { buildSessionBasePrefix } from '../lib/keys';
import {
  CreateSessionRequestSchema,
  CreateSessionResponse,
  ValidationError,
  AuthenticationError,
} from '../lib/types';

const BUCKET = process.env.S3_BUCKET_NAME || '';
const MAX_CHUNK_BYTES = 5 * 1024 * 1024; // 5MB (single-part limit)

/**
 * POST /sessions - Create a new audio recording session
 */
export async function handler(
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> {
  try {
    // Authenticate user
    const user = await authenticateRequest(event);

    // Parse and validate request body
    const body = event.body ? JSON.parse(event.body) : {};
    const request = CreateSessionRequestSchema.parse(body);

    // Generate unique session ID
    const sessionId = `session-${Date.now()}-${uuidv4()}`;

    // Build S3 base prefix
    const basePrefix = buildSessionBasePrefix(user.sub, sessionId);

    // Prepare response
    const response: CreateSessionResponse = {
      sessionId,
      s3: {
        bucket: BUCKET,
        basePrefix,
      },
      uploadStrategy: 'single', // TODO: Support multipart for chunks > 5MB
      maxChunkBytes: MAX_CHUNK_BYTES,
    };

    console.log('Session created:', {
      userId: user.sub,
      sessionId,
      codec: request.codec,
      sampleRate: request.sampleRate,
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
    console.error('Error creating session:', error);

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
