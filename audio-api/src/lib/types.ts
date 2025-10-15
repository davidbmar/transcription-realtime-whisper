import { z } from 'zod';

// ============================================================================
// Request/Response DTOs with runtime validation
// ============================================================================

// POST /sessions - Create session
export const CreateSessionRequestSchema = z.object({
  codec: z.string().default('webm/opus'),
  sampleRate: z.number().default(48000),
  chunkSeconds: z.number().min(1).max(300).default(5),
  deviceInfo: z.object({
    userAgent: z.string().optional(),
  }).optional(),
});

export type CreateSessionRequest = z.infer<typeof CreateSessionRequestSchema>;

export interface CreateSessionResponse {
  sessionId: string;
  s3: {
    bucket: string;
    basePrefix: string; // users/<uid>/audio/sessions/<sid>/chunks/
  };
  uploadStrategy: 'single' | 'multipart';
  maxChunkBytes: number;
}

// POST /sessions/{sessionId}/chunks/presign - Presign chunk upload
export const PresignChunkRequestSchema = z.object({
  seq: z.number().int().positive(),
  tStartMs: z.number().int().nonnegative(),
  tEndMs: z.number().int().positive(),
  ext: z.string(),
  sizeBytes: z.number().int().positive(),
  contentType: z.string(),
});

export type PresignChunkRequest = z.infer<typeof PresignChunkRequestSchema>;

export interface PresignChunkResponse {
  objectKey: string;
  putUrl: string;
  headers: {
    'Content-Type': string;
    'x-amz-meta-user-id': string;
    'x-amz-meta-session-id': string;
    'x-amz-meta-seq': string;
  };
  expiresInSeconds: number;
}

// POST /sessions/{sessionId}/chunks/complete - Confirm chunk upload
export const CompleteChunkRequestSchema = z.object({
  seq: z.number().int().positive(),
  objectKey: z.string(),
  bytes: z.number().int().positive(),
  tStartMs: z.number().int().nonnegative(),
  tEndMs: z.number().int().positive(),
  md5: z.string().optional(),
  sha256: z.string().optional(),
});

export type CompleteChunkRequest = z.infer<typeof CompleteChunkRequestSchema>;

export interface CompleteChunkResponse {
  ok: boolean;
  eventId?: string;
}

// PUT /sessions/{sessionId}/manifest - Upsert manifest
export const UpsertManifestRequestSchema = z.object({
  sessionId: z.string(),
  codec: z.string(),
  sampleRate: z.number(),
  chunks: z.array(z.object({
    seq: z.number(),
    key: z.string(),
    tStartMs: z.number(),
    tEndMs: z.number(),
    bytes: z.number(),
  })),
  final: z.boolean(),
});

export type UpsertManifestRequest = z.infer<typeof UpsertManifestRequestSchema>;

export interface UpsertManifestResponse {
  ok: boolean;
  manifestKey: string;
}

// POST /sessions/{sessionId}/finalize - Seal manifest
export const FinalizeSessionRequestSchema = z.object({
  durationMs: z.number().int().positive(),
  final: z.boolean().default(true),
});

export type FinalizeSessionRequest = z.infer<typeof FinalizeSessionRequestSchema>;

export interface FinalizeSessionResponse {
  ok: boolean;
  manifestKey: string;
  chunkCount: number;
  totalBytes: number;
}

// ============================================================================
// Internal types
// ============================================================================

export interface ChunkMetadata {
  seq: number;
  key: string;
  tStartMs: number;
  tEndMs: number;
  bytes: number;
  uploadedAt?: string;
  md5?: string;
  sha256?: string;
}

export interface SessionManifest {
  sessionId: string;
  userId: string;
  codec: string;
  sampleRate: number;
  chunks: ChunkMetadata[];
  final: boolean;
  createdAt: string;
  updatedAt: string;
  totalBytes?: number;
  durationMs?: number;
}

export interface CognitoUser {
  sub: string;
  email: string;
  'cognito:username': string;
}

// ============================================================================
// Error types
// ============================================================================

export class ValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ValidationError';
  }
}

export class AuthenticationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AuthenticationError';
  }
}

export class NotFoundError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotFoundError';
  }
}
