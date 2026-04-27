import jwt from 'jsonwebtoken';
import jwksClient from 'jwks-rsa';
import { DynamoDBClient, ScanCommand } from '@aws-sdk/client-dynamodb';

/**
 * Multi-tenant Lambda authorizer for client_credentials JWT tokens.
 *
 * Used by the totptoken API endpoint. ASM obtains a token via the
 * OAuth2 client_credentials grant on each tenant's Cognito UserPool
 * (scope: amfa/totptoken). This authorizer:
 *
 * 1. Decodes JWT (no verification) to extract the issuer → userPoolId
 * 2. Looks up the tenant by userPoolId from DynamoDB (cached)
 * 3. Verifies the JWT signature against the matched UserPool's JWKS
 * 4. Validates the token has the required scope (amfa/totptoken)
 * 5. Returns { isAuthorized, context: { tenantId, userPoolId } }
 *
 * Key difference from the regular multi-tenant-authorizer:
 * - client_credentials tokens do NOT have an `aud` (audience) claim
 * - Instead we validate the `scope` claim contains 'amfa/totptoken'
 */

// Structured logger
const _LL = { DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3 };
const _ML = _LL[(process.env.LOG_LEVEL || 'INFO').toUpperCase()] ?? 1;
const _createLogger = (svc) => {
  let _pk = {};
  const _l = (lvl, msg, ex = {}) => {
    if ((_LL[lvl] ?? 0) >= _ML) {
      const extra = (typeof ex === 'object' && ex !== null && !(ex instanceof Error))
        ? ex : { detail: String(ex) };
      console.log(JSON.stringify({
        timestamp: new Date().toISOString(), level: lvl, service: svc,
        message: msg, ..._pk, ...extra,
      }));
    }
  };
  return {
    info:  (m, e) => _l('INFO',  m, e),
    warn:  (m, e) => _l('WARN',  m, e),
    error: (m, e) => _l('ERROR', m, e),
    debug: (m, e) => _l('DEBUG', m, e),
    appendKeys: (k) => { _pk = { ..._pk, ...k }; },
    resetKeys:  ()  => { _pk = {}; },
  };
};
const logger = _createLogger('totptoken-authorizer');

// ---------------------------------------------------------------------------
// JWKS client cache (per userPoolId)
// ---------------------------------------------------------------------------
const jwksClients = new Map();

function getJwksClient(region, userPoolId) {
  const key = `${region}:${userPoolId}`;
  if (!jwksClients.has(key)) {
    jwksClients.set(key, jwksClient({
      jwksUri: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}/.well-known/jwks.json`,
      cache: true,
      cacheMaxEntries: 5,
      cacheMaxAge: 600_000,
    }));
  }
  return jwksClients.get(key);
}

function getSigningKey(client, kid) {
  return new Promise((resolve, reject) => {
    client.getSigningKey(kid, (err, key) => {
      if (err) reject(err);
      else resolve(key.getPublicKey());
    });
  });
}

// ---------------------------------------------------------------------------
// Tenant data cache (DynamoDB)
// ---------------------------------------------------------------------------
let tenantsByUserPoolId = null;
let tenantsCacheTimestamp = 0;
const TENANTS_CACHE_TTL = 5 * 60 * 1000; // 5 minutes

const dynamodb = new DynamoDBClient({ region: process.env.AWS_REGION || 'us-east-1' });

async function loadTenantsByUserPoolId() {
  const now = Date.now();
  if (tenantsByUserPoolId && (now - tenantsCacheTimestamp) < TENANTS_CACHE_TTL) {
    return tenantsByUserPoolId;
  }

  const tableName = process.env.TENANT_TABLE || 'amfa-tenanttable';

  const result = await dynamodb.send(new ScanCommand({
    TableName: tableName,
    FilterExpression: 'begins_with(id, :prefix)',
    ExpressionAttributeValues: { ':prefix': { S: 'TENANT#' } },
    ProjectionExpression: 'id, userpool',
  }));

  const map = new Map();
  for (const item of (result.Items || [])) {
    const tenantId = item.id?.S?.replace('TENANT#', '');
    const userPoolId = item.userpool?.S;
    if (tenantId && userPoolId) {
      map.set(userPoolId, tenantId);
    }
  }

  tenantsByUserPoolId = map;
  tenantsCacheTimestamp = now;
  logger.info(`Loaded ${map.size} tenant(s) indexed by userPoolId`);
  return map;
}

// ---------------------------------------------------------------------------
// JWT helpers
// ---------------------------------------------------------------------------

/**
 * Decode JWT (without verification) to extract issuer → userPoolId.
 * Safe because the extracted userPoolId is only used to SELECT
 * which public key to verify against.
 */
function extractIssuerInfo(token) {
  try {
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded?.payload?.iss) return null;

    const issuer = decoded.payload.iss;
    const parts = issuer.split('/');
    const userPoolId = parts[parts.length - 1];

    // Cognito UserPool IDs always contain underscore: {region}_{id}
    if (!userPoolId || !userPoolId.includes('_')) {
      logger.warn('Invalid userPoolId format in issuer', { issuer });
      return null;
    }
    return { userPoolId, issuer };
  } catch (error) {
    logger.warn('Failed to decode JWT for issuer extraction', { error: error.message });
    return null;
  }
}

/**
 * Verify JWT token against a specific user pool.
 *
 * Unlike the regular multi-tenant-authorizer:
 * - No audience verification (client_credentials tokens have no aud)
 * - Validates scope contains 'amfa/totptoken'
 */
async function verifyToken(token, region, userPoolId) {
  const decoded = jwt.decode(token, { complete: true });
  if (!decoded?.header?.kid) {
    throw new Error('Invalid token structure — missing kid');
  }

  const client = getJwksClient(region, userPoolId);
  const signingKey = await getSigningKey(client, decoded.header.kid);

  const payload = jwt.verify(token, signingKey, {
    algorithms: ['RS256'],
    issuer: `https://cognito-idp.${region}.amazonaws.com/${userPoolId}`,
    // NOTE: no audience — client_credentials tokens do not carry aud
  });

  // Validate scope
  const scope = payload.scope || '';
  if (!scope.includes('amfa/totptoken')) {
    throw new Error(`Token missing required scope amfa/totptoken (got: ${scope})`);
  }

  return payload;
}

// ---------------------------------------------------------------------------
// Handler (HTTP API v2 SIMPLE response format)
// ---------------------------------------------------------------------------

function generateResponse(isAuthorized, context = {}) {
  return { isAuthorized, context };
}

export const handler = async (event) => {
  logger.debug('Event received', {
    routeArn: event.routeArn,
    headers: event.headers ? Object.keys(event.headers) : [],
  });

  try {
    // 1. Extract token
    const raw = event.headers?.authorization || event.authorizationToken;
    if (!raw) throw new Error('No authorization token provided');
    const token = raw.replace(/^Bearer\s+/i, '');

    const region = process.env.AWS_REGION || 'us-east-1';

    // 2. Decode to extract issuer
    const issuerInfo = extractIssuerInfo(token);
    if (!issuerInfo) throw new Error('Invalid token — could not extract issuer');

    logger.debug('Issuer extracted', { userPoolId: issuerInfo.userPoolId });

    // 3. Look up tenant by userPoolId (O(1) via Map)
    const map = await loadTenantsByUserPoolId();
    const tenantId = map.get(issuerInfo.userPoolId);
    if (!tenantId) {
      logger.warn('No tenant found for userPoolId', { userPoolId: issuerInfo.userPoolId });
      throw new Error('Unknown user pool — unauthorized');
    }

    logger.info('Matched tenant', { tenantId, userPoolId: issuerInfo.userPoolId });

    // 4. Verify JWT
    const payload = await verifyToken(token, region, issuerInfo.userPoolId);

    logger.info('Token verified', { tenantId, scope: payload.scope });

    // 5. Return authorized with tenant context
    return generateResponse(true, {
      tenantId,
      userPoolId: issuerInfo.userPoolId,
    });
  } catch (error) {
    logger.error('Authorization failed', { error: error.message });
    return generateResponse(false, { error: error.message });
  }
};
