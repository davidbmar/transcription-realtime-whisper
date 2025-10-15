import {
  S3Client,
  PutObjectCommand,
  HeadObjectCommand,
  GetObjectCommand,
  ListObjectsV2Command,
} from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { SessionManifest, ChunkMetadata, NotFoundError } from './types';

const REGION = process.env.REGION || 'us-east-2';
const BUCKET = process.env.S3_BUCKET_NAME || '';

const s3Client = new S3Client({ region: REGION });

/**
 * Generate presigned PUT URL for chunk upload
 */
export async function generatePresignedPutUrl(
  key: string,
  contentType: string,
  metadata: Record<string, string>,
  expiresIn: number = 300 // 5 minutes
): Promise<string> {
  const command = new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    ContentType: contentType,
    Metadata: metadata,
    ServerSideEncryption: 'AES256', // or 'aws:kms' for KMS
  });

  return await getSignedUrl(s3Client, command, { expiresIn });
}

/**
 * Check if an object exists in S3
 */
export async function objectExists(key: string): Promise<boolean> {
  try {
    await s3Client.send(new HeadObjectCommand({
      Bucket: BUCKET,
      Key: key,
    }));
    return true;
  } catch (error: any) {
    if (error.name === 'NotFound') {
      return false;
    }
    throw error;
  }
}

/**
 * Get object metadata from S3
 */
export async function getObjectMetadata(key: string): Promise<{
  size: number;
  contentType: string;
  metadata: Record<string, string>;
}> {
  try {
    const response = await s3Client.send(new HeadObjectCommand({
      Bucket: BUCKET,
      Key: key,
    }));

    return {
      size: response.ContentLength || 0,
      contentType: response.ContentType || '',
      metadata: response.Metadata || {},
    };
  } catch (error: any) {
    if (error.name === 'NotFound') {
      throw new NotFoundError(`Object not found: ${key}`);
    }
    throw error;
  }
}

/**
 * Read session manifest from S3
 */
export async function readManifest(key: string): Promise<SessionManifest | null> {
  try {
    const response = await s3Client.send(new GetObjectCommand({
      Bucket: BUCKET,
      Key: key,
    }));

    if (!response.Body) {
      return null;
    }

    const bodyString = await response.Body.transformToString();
    return JSON.parse(bodyString) as SessionManifest;
  } catch (error: any) {
    if (error.name === 'NoSuchKey' || error.name === 'NotFound') {
      return null;
    }
    throw error;
  }
}

/**
 * Write session manifest to S3
 */
export async function writeManifest(
  key: string,
  manifest: SessionManifest
): Promise<void> {
  await s3Client.send(new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    Body: JSON.stringify(manifest, null, 2),
    ContentType: 'application/json',
    ServerSideEncryption: 'AES256',
  }));
}

/**
 * Merge chunk into manifest (read-modify-write with optimistic locking via ETag)
 */
export async function mergeChunkIntoManifest(
  manifestKey: string,
  chunk: ChunkMetadata,
  userId: string,
  sessionId: string,
  codec: string,
  sampleRate: number
): Promise<SessionManifest> {
  // Read existing manifest or create new
  let manifest = await readManifest(manifestKey);

  if (!manifest) {
    // Create new manifest
    manifest = {
      sessionId,
      userId,
      codec,
      sampleRate,
      chunks: [],
      final: false,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
  }

  // Update timestamp
  manifest.updatedAt = new Date().toISOString();

  // Add or update chunk (by sequence number)
  const existingIndex = manifest.chunks.findIndex(c => c.seq === chunk.seq);

  if (existingIndex >= 0) {
    // Update existing chunk
    manifest.chunks[existingIndex] = chunk;
  } else {
    // Add new chunk
    manifest.chunks.push(chunk);
  }

  // Sort chunks by sequence number
  manifest.chunks.sort((a, b) => a.seq - b.seq);

  // Calculate totals
  manifest.totalBytes = manifest.chunks.reduce((sum, c) => sum + c.bytes, 0);

  // Calculate duration from last chunk end time
  if (manifest.chunks.length > 0) {
    manifest.durationMs = Math.max(...manifest.chunks.map(c => c.tEndMs));
  }

  // Write back to S3
  await writeManifest(manifestKey, manifest);

  return manifest;
}

/**
 * List all chunks for a session (from S3)
 */
export async function listSessionChunks(prefix: string): Promise<string[]> {
  const response = await s3Client.send(new ListObjectsV2Command({
    Bucket: BUCKET,
    Prefix: prefix,
  }));

  if (!response.Contents) {
    return [];
  }

  return response.Contents
    .filter(obj => obj.Key && obj.Key.match(/\.webm$|\.wav$|\.mp3$/))
    .map(obj => obj.Key as string)
    .sort();
}
