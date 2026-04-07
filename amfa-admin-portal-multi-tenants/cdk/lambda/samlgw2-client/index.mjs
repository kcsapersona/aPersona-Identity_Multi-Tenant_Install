/**
 * SAML Gateway v2 (samlgw2) API Client
 *
 * Shared module for all lambdas that interact with the samlgw2 REST API.
 *
 * Architecture mapping:
 *   IT Svc Org (admin portal) → samlgw2 IT Org (id: "{awsAccountHash}-{itsvcorgid}")
 *   Tenant (admin portal)     → samlgw2 Customer (name: tenantId)
 *   SAML SP (admin portal)    → samlgw2 Relying Party (name: rpName)
 *
 * Auth: X-Admin-Token header with static token stored in Secrets Manager.
 *
 * URL patterns:
 *   IDP Metadata:   {baseUrl}/samlidp/{itorg}/{customer}/{rp}.xml
 *   OIDC Callback:  {baseUrl}/oidcsp/{itorg}/{customer}/{rp}/upstream/cb
 */

import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from "@aws-sdk/client-secrets-manager";

// Structured logger (2.2) - inline since this Lambda does not use admin-auth layer
const _LL = { DEBUG: 0, INFO: 1, WARN: 2, ERROR: 3 };
const _ML = _LL[(process.env.LOG_LEVEL || 'INFO').toUpperCase()] ?? 1;
const createLogger = (svc) => {
  let _pk = {};
  const _l = (lvl, msg, ex = {}) => { if ((_LL[lvl]??0) >= _ML) console.log(JSON.stringify({ timestamp: new Date().toISOString(), level: lvl, service: svc, message: msg, ..._pk, ...ex })); };
  return { info: (m,e) => _l('INFO',m,e), warn: (m,e) => _l('WARN',m,e), error: (m,e) => _l('ERROR',m,e), debug: (m,e) => _l('DEBUG',m,e), appendKeys: (k) => { _pk = {..._pk,...k}; }, resetKeys: () => { _pk = {}; } };
};

const logger = createLogger('samlgw2-client');

const secretsManager = new SecretsManagerClient({
  region: process.env.AWS_REGION,
});

// Cache the admin token in memory (Lambda warm start reuse)
let cachedAdminToken = null;

/**
 * Hash an AWS Account ID to a short deterministic string.
 * Used to prefix IT Org IDs to ensure global uniqueness across AWS accounts.
 *
 * Uses Java-style String.hashCode() → base36, same algorithm as userpool domain hash.
 *
 * @param {string} accountId - 12-digit AWS account ID
 * @returns {string} Short hash string (e.g., "k4f9m2")
 */
export function hashAwsAccount(accountId) {
  const str = (accountId || "").toLowerCase();
  let hash = 0;
  for (let i = 0; i < str.length; i++) {
    hash = ((hash << 5) - hash + str.charCodeAt(i)) | 0;
  }
  return (hash >>> 0).toString(36);
}

/**
 * Build the samlgw2 IT Org ID from AWS account + IT Svc Org ID.
 *
 * Format: "{hash(awsAccountId)}-{itsvcorgid}"
 * All lowercase as required by samlgw2.
 *
 * @param {string} awsAccountId - AWS account ID
 * @param {string} orgId - IT Svc Org ID from admin portal
 * @returns {string} samlgw2-compatible IT Org ID
 */
export function buildSamlgw2ItorgId(awsAccountId, orgId) {
  const accountHash = hashAwsAccount(awsAccountId);
  return `${accountHash}-${orgId}`.toLowerCase();
}

/**
 * Get the admin token from Secrets Manager (with caching).
 *
 * @param {string} secretName - Secret name in Secrets Manager
 * @returns {Promise<string>} The admin token
 */
async function getAdminToken(secretName) {
  if (cachedAdminToken) {
    return cachedAdminToken;
  }

  const response = await secretsManager.send(
    new GetSecretValueCommand({ SecretId: secretName })
  );

  const secretData = JSON.parse(response.SecretString);
  cachedAdminToken = secretData.adminToken;
  return cachedAdminToken;
}

/**
 * SAML Gateway v2 API Client
 */
export class SamlGw2Client {
  /**
   * @param {string} baseUrl - samlgw2 base URL (e.g., "https://samlgw2.apersona-id.com")
   * @param {string} adminTokenSecretName - Secrets Manager secret name for admin token
   */
  constructor(baseUrl, adminTokenSecretName) {
    this.baseUrl = baseUrl;
    this.apiBase = `${baseUrl}/api`;
    this.adminTokenSecretName = adminTokenSecretName;
  }

  /**
   * Make an authenticated API request to samlgw2.
   *
   * @param {string} method - HTTP method
   * @param {string} path - API path (relative to /api)
   * @param {Object|null} body - Request body (for POST/PUT)
   * @returns {Promise<Object>} Parsed JSON response
   * @throws {Error} On HTTP errors
   */
  async request(method, path, body = null) {
    const token = await getAdminToken(this.adminTokenSecretName);
    const url = `${this.apiBase}${path}`;

    logger.info(`[SamlGw2] ====== API Request ======`);
    logger.info(`[SamlGw2] ${method} ${url}`);

    const options = {
      method,
      headers: {
        "X-Admin-Token": token,
        "Content-Type": "application/json",
      },
    };

    if (body && (method === "POST" || method === "PUT")) {
      options.body = JSON.stringify(body);
      logger.info(`[SamlGw2] Request Body:`, JSON.stringify(body, null, 2));
    }

    let response;
    try {
      response = await fetch(url, options);
    } catch (fetchError) {
      logger.error(`[SamlGw2] ====== Fetch Error ======`);
      logger.error(`[SamlGw2] Failed to connect to ${url}`);
      logger.error(`[SamlGw2] Error:`, fetchError.message);
      logger.error(`[SamlGw2] Stack:`, fetchError.stack);
      throw fetchError;
    }

    logger.info(`[SamlGw2] Response Status: ${response.status} ${response.statusText}`);
    logger.info(`[SamlGw2] Response Headers:`, JSON.stringify(Object.fromEntries(response.headers.entries())));

    // DELETE returns 204 No Content
    if (response.status === 204) {
      logger.info(`[SamlGw2] ====== Success (204 No Content) ======`);
      return { success: true };
    }

    const responseText = await response.text();
    logger.info(`[SamlGw2] Response Body:`, responseText);

    if (!response.ok) {
      logger.error(`[SamlGw2] ====== API Error ======`);
      logger.error(`[SamlGw2] Status: ${response.status}`);
      logger.error(`[SamlGw2] Body: ${responseText}`);
      const error = new Error(
        `SamlGw2 API error (${response.status}): ${responseText}`
      );
      error.status = response.status;
      try {
        error.detail = JSON.parse(responseText);
      } catch {
        error.detail = responseText;
      }
      throw error;
    }

    logger.info(`[SamlGw2] ====== Success (${response.status}) ======`);

    try {
      return JSON.parse(responseText);
    } catch {
      return { raw: responseText };
    }
  }

  // ==================== IT Org Operations ====================

  /**
   * List all IT Organizations.
   * @returns {Promise<Object>} { count, itorgs: string[] }
   */
  async listItOrgs() {
    return this.request("GET", "/itorgs");
  }

  /**
   * Create an IT Organization.
   * @param {string} itorgId - IT Org ID (must be lowercase)
   * @returns {Promise<Object>} { message, itorg, path }
   */
  async createItOrg(itorgId) {
    return this.request("POST", "/itorgs", { itorg: itorgId.toLowerCase() });
  }

  // ==================== Customer Operations ====================

  /**
   * List all customers for an IT Organization.
   * @param {string} itorgId - IT Org ID
   * @returns {Promise<Object>} { itorg, count, customers: [...] }
   */
  async listCustomers(itorgId) {
    return this.request("GET", `/itorgs/${itorgId}/customers`);
  }

  /**
   * Get a single customer.
   * @param {string} itorgId - IT Org ID
   * @param {string} customerName - Customer name (tenant ID)
   * @returns {Promise<Object>} Customer data with relying_parties
   */
  async getCustomer(itorgId, customerName) {
    return this.request(
      "GET",
      `/itorgs/${itorgId}/customers/${customerName}`
    );
  }

  /**
   * Create a customer for an IT Organization.
   *
   * @param {string} itorgId - IT Org ID
   * @param {Object} customerData - Customer data
   * @param {string} customerData.name - Customer name (tenant ID, lowercase)
   * @param {string} customerData.phone - Contact phone
   * @param {string} customerData.email - Contact email
   * @param {Object} customerData.oidc - OIDC configuration
   * @param {string} customerData.oidc.issuer - Cognito UserPool issuer URL
   * @param {string} customerData.oidc.well_known - OIDC well-known URL
   * @param {string} customerData.oidc.authorization_endpoint - OAuth2 authorize URL
   * @param {string} customerData.oidc.token_endpoint - OAuth2 token URL
   * @param {string} customerData.oidc.client_id - SAML client ID
   * @param {string} customerData.oidc.client_secret - SAML client secret
   * @param {string} customerData.oidc.scope - OAuth2 scopes
   * @returns {Promise<Object>} { message, itorg, customer }
   */
  async createCustomer(itorgId, customerData) {
    return this.request(
      "POST",
      `/itorgs/${itorgId}/customers`,
      customerData
    );
  }

  // ==================== Relying Party Operations ====================

  /**
   * Create or update a SAML Relying Party for a customer.
   *
   * @param {string} itorgId - IT Org ID
   * @param {string} customerName - Customer name (tenant ID)
   * @param {string} rpName - Relying Party name (slug, lowercase)
   * @param {Object} rpConfig - RP configuration
   * @param {string} rpConfig.display_name - Display name
   * @param {string} rpConfig.login_url - SP login URL
   * @param {string} rpConfig.logo_url - Logo URL
   * @param {Object} rpConfig.sp - SP metadata config
   * @param {string} rpConfig.sp.metadata_url - SP metadata URL
   * @param {Object} rpConfig.claim_mappings - Claim mappings
   * @param {Object} rpConfig.claim_mappings.saml_to_oidc - SAML→OIDC mappings
   * @param {Object} rpConfig.claim_mappings.oidc_to_saml - OIDC→SAML mappings
   * @param {Object} rpConfig.saml - SAML settings
   * @param {Object} rpConfig.saml.nameid - NameID config (format, source_claim)
   * @returns {Promise<Object>} { message, itorg, customer, relying_party }
   */
  async createRelyingParty(itorgId, customerName, rpName, rpConfig) {
    return this.request(
      "POST",
      `/itorgs/${itorgId}/customers/${customerName}/relying-parties/${rpName.toLowerCase()}`,
      rpConfig
    );
  }

  /**
   * Delete a SAML Relying Party from a customer.
   *
   * @param {string} itorgId - IT Org ID
   * @param {string} customerName - Customer name (tenant ID)
   * @param {string} rpName - Relying Party name
   * @returns {Promise<Object>} { success: true } on 204
   */
  async deleteRelyingParty(itorgId, customerName, rpName) {
    return this.request(
      "DELETE",
      `/itorgs/${itorgId}/customers/${customerName}/relying-parties/${rpName.toLowerCase()}`
    );
  }

  // ==================== URL Builders ====================

  /**
   * Get the IDP SAML Metadata URL for a relying party.
   * This URL is given to the SP (e.g., Microsoft Entra) to configure federation.
   *
   * @param {string} itorgId - IT Org ID
   * @param {string} customerName - Customer name
   * @param {string} rpName - Relying Party name
   * @returns {string} IDP metadata URL
   */
  getIdpMetadataUrl(itorgId, customerName, rpName) {
    return `${this.baseUrl}/samlidp/${itorgId}/${customerName}/${rpName}.xml`;
  }

  /**
   * Get the OIDC callback URL for a relying party.
   * This URL must be added to the Cognito SAML client's CallbackURLs.
   *
   * @param {string} itorgId - IT Org ID
   * @param {string} customerName - Customer name
   * @param {string} rpName - Relying Party name
   * @returns {string} OIDC callback URL
   */
  getOidcCallbackUrl(itorgId, customerName, rpName) {
    return `${this.baseUrl}/oidcsp/${itorgId}/${customerName}/${rpName}/upstream/cb`;
  }
}

/**
 * Create a SamlGw2Client from environment variables.
 *
 * Expected env vars:
 *   SAMLGW2_BASE_URL - Base URL (e.g., "https://samlgw2.apersona-id.com")
 *   SAMLGW2_ADMIN_TOKEN_SECRET_NAME - Secrets Manager secret name
 *
 * @returns {SamlGw2Client}
 */
export function createSamlGw2ClientFromEnv() {
  const baseUrl = process.env.SAMLGW2_BASE_URL;
  const secretName = process.env.SAMLGW2_ADMIN_TOKEN_SECRET_NAME;

  if (!baseUrl || !secretName) {
    throw new Error(
      "SAMLGW2_BASE_URL and SAMLGW2_ADMIN_TOKEN_SECRET_NAME environment variables are required"
    );
  }

  return new SamlGw2Client(baseUrl, secretName);
}

export default SamlGw2Client;
