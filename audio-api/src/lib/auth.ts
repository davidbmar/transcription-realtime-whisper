import { APIGatewayProxyEvent } from 'aws-lambda';
import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';
import { CognitoUser, AuthenticationError } from './types';

const USER_POOL_ID = process.env.USER_POOL_ID || '';
const REGION = process.env.REGION || 'us-east-2';

// JWKS client for Cognito public keys
const jwksUri = `https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}/.well-known/jwks.json`;
const client = jwksClient({
  jwksUri,
  cache: true,
  cacheMaxAge: 600000, // 10 minutes
});

/**
 * Get signing key from JWKS endpoint
 */
function getKey(header: jwt.JwtHeader, callback: jwt.SigningKeyCallback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) {
      callback(err);
      return;
    }
    const signingKey = key?.getPublicKey();
    callback(null, signingKey);
  });
}

/**
 * Verify JWT token from Cognito
 */
export async function verifyToken(token: string): Promise<CognitoUser> {
  return new Promise((resolve, reject) => {
    jwt.verify(token, getKey, {
      algorithms: ['RS256'],
      issuer: `https://cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}`,
    }, (err, decoded) => {
      if (err) {
        reject(new AuthenticationError(`Token verification failed: ${err.message}`));
        return;
      }

      if (!decoded || typeof decoded === 'string') {
        reject(new AuthenticationError('Invalid token payload'));
        return;
      }

      // Extract Cognito user info
      const user: CognitoUser = {
        sub: decoded.sub as string,
        email: decoded.email as string,
        'cognito:username': decoded['cognito:username'] as string,
      };

      resolve(user);
    });
  });
}

/**
 * Extract and verify JWT from API Gateway event
 */
export async function authenticateRequest(event: APIGatewayProxyEvent): Promise<CognitoUser> {
  // Get token from Authorization header
  const authHeader = event.headers['Authorization'] || event.headers['authorization'];

  if (!authHeader) {
    throw new AuthenticationError('Missing Authorization header');
  }

  // Extract Bearer token
  const match = authHeader.match(/^Bearer (.+)$/);
  if (!match) {
    throw new AuthenticationError('Invalid Authorization header format');
  }

  const token = match[1];

  // Verify token and return user
  return await verifyToken(token);
}
