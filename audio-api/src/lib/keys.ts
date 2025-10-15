import { ValidationError } from './types';

/**
 * Sanitize session ID to prevent path traversal
 */
export function sanitizeSessionId(sessionId: string): string {
  // Allow only alphanumeric, hyphens, and underscores
  const sanitized = sessionId.replace(/[^a-zA-Z0-9\-_]/g, '');

  if (!sanitized || sanitized.length < 1) {
    throw new ValidationError('Invalid session ID');
  }

  return sanitized;
}

/**
 * Build S3 key for audio chunk with strict user isolation
 * Pattern: users/{userId}/audio/sessions/{sessionId}/chunks/{seq}-{tStartMs}-{tEndMs}.{ext}
 */
export function buildChunkKey(
  userId: string,
  sessionId: string,
  seq: number,
  tStartMs: number,
  tEndMs: number,
  ext: string
): string {
  // Sanitize inputs
  const sanitizedUserId = userId.replace(/[^a-zA-Z0-9\-_]/g, '');
  const sanitizedSessionId = sanitizeSessionId(sessionId);
  const sanitizedExt = ext.replace(/[^a-zA-Z0-9]/g, '');

  // Validate
  if (!sanitizedUserId) {
    throw new ValidationError('Invalid user ID');
  }

  if (seq < 1) {
    throw new ValidationError('Sequence number must be positive');
  }

  if (tStartMs < 0 || tEndMs <= tStartMs) {
    throw new ValidationError('Invalid time range');
  }

  // Build key with zero-padded sequence number
  const seqPadded = seq.toString().padStart(5, '0');
  const tStartPadded = tStartMs.toString().padStart(6, '0');
  const tEndPadded = tEndMs.toString().padStart(6, '0');

  return `users/${sanitizedUserId}/audio/sessions/${sanitizedSessionId}/chunks/${seqPadded}-${tStartPadded}-${tEndPadded}.${sanitizedExt}`;
}

/**
 * Build S3 key for session manifest
 * Pattern: users/{userId}/audio/sessions/{sessionId}/manifest.json
 */
export function buildManifestKey(userId: string, sessionId: string): string {
  const sanitizedUserId = userId.replace(/[^a-zA-Z0-9\-_]/g, '');
  const sanitizedSessionId = sanitizeSessionId(sessionId);

  if (!sanitizedUserId) {
    throw new ValidationError('Invalid user ID');
  }

  return `users/${sanitizedUserId}/audio/sessions/${sanitizedSessionId}/manifest.json`;
}

/**
 * Build base prefix for session chunks
 * Pattern: users/{userId}/audio/sessions/{sessionId}/chunks/
 */
export function buildSessionBasePrefix(userId: string, sessionId: string): string {
  const sanitizedUserId = userId.replace(/[^a-zA-Z0-9\-_]/g, '');
  const sanitizedSessionId = sanitizeSessionId(sessionId);

  if (!sanitizedUserId) {
    throw new ValidationError('Invalid user ID');
  }

  return `users/${sanitizedUserId}/audio/sessions/${sanitizedSessionId}/chunks/`;
}

/**
 * Verify that a key starts with the correct user prefix
 * Prevents privilege escalation by verifying user owns the resource
 */
export function enforceUserPrefix(key: string, userId: string): void {
  const expectedPrefix = `users/${userId}/`;

  if (!key.startsWith(expectedPrefix)) {
    throw new ValidationError(`Key does not match user prefix: ${expectedPrefix}`);
  }
}

/**
 * Extract session ID from a chunk key
 */
export function extractSessionIdFromKey(key: string): string | null {
  // Pattern: users/{userId}/audio/sessions/{sessionId}/chunks/...
  const match = key.match(/^users\/[^\/]+\/audio\/sessions\/([^\/]+)\/chunks\//);
  return match ? match[1] : null;
}

/**
 * Extract sequence number from chunk key
 */
export function extractSeqFromKey(key: string): number | null {
  // Pattern: .../chunks/{seq}-{tStartMs}-{tEndMs}.{ext}
  const match = key.match(/\/chunks\/(\d+)-\d+-\d+\.[^\/]+$/);
  return match ? parseInt(match[1], 10) : null;
}
