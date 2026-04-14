/**
 * Platform Info Lambda
 * 
 * Returns global platform information (NAT IP address, etc.) for SA users only.
 * This endpoint is protected by:
 * 1. API Gateway authorizer (requires valid JWT)
 * 2. SA role check inside this Lambda (JWT groups must contain "SA")
 */
import { SSMClient, GetParameterCommand } from '@aws-sdk/client-ssm';

const ssmClient = new SSMClient({ region: process.env.AWS_REGION });

// Cache SSM value in Lambda warm start
let cachedNatIp = null;

/**
 * Extract user groups from JWT Authorization header
 */
function extractGroupsFromToken(authHeader) {
  if (!authHeader) return [];

  try {
    const jwt = authHeader.replace('Bearer ', '');
    const payload = JSON.parse(
      Buffer.from(jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('ascii')
    );

    let groups = payload['cognito:groups'] || [];
    if (typeof groups === 'string') {
      groups = groups.match(/[^\[\]\s]+/g) || [];
    }
    return groups;
  } catch {
    return [];
  }
}

export const handler = async (event) => {
  console.info('Platform Info Lambda EVENT\n' + JSON.stringify(event, null, 2));

  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type,Authorization,X-Api-Key,X-Requested-With',
    'Access-Control-Allow-Methods': 'OPTIONS,GET',
    'Content-Type': 'application/json',
  };

  // Handle OPTIONS preflight
  const method = event.requestContext?.http?.method || event.httpMethod || 'GET';
  if (method === 'OPTIONS') {
    return { statusCode: 200, headers: corsHeaders, body: '{}' };
  }

  // Only allow GET
  if (method !== 'GET') {
    return {
      statusCode: 405,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Method not allowed' }),
    };
  }

  // SA role check: extract groups from JWT and verify SA membership
  const authHeader = event.headers?.authorization || event.headers?.Authorization;
  const groups = extractGroupsFromToken(authHeader);
  const isSA = groups.includes('SA');

  if (!isSA) {
    return {
      statusCode: 403,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Access denied. Super Admin role required.' }),
    };
  }

  try {
    // Read NAT IP from SSM (with Lambda warm-start caching)
    if (!cachedNatIp) {
      const result = await ssmClient.send(new GetParameterCommand({
        Name: '/amfa/vpc/nat-eip-address',
      }));
      cachedNatIp = result.Parameter?.Value || null;
    }

    return {
      statusCode: 200,
      headers: corsHeaders,
      body: JSON.stringify({
        data: {
          natIpAddress: cachedNatIp,
        },
      }),
    };
  } catch (err) {
    console.error('Failed to fetch platform info:', err);
    return {
      statusCode: 500,
      headers: corsHeaders,
      body: JSON.stringify({ error: 'Failed to fetch platform info' }),
    };
  }
};
