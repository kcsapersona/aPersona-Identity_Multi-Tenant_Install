/**
 * Tenant Configuration for Multi-Tenant Architecture
 *
 * In the new architecture:
 * - CDK deploys SHARED infrastructure only (no tenant-specific resources)
 * - Tenants are provisioned at RUNTIME via provision-tenant Lambda
 * - This config returns empty array to indicate "shared infrastructure only"
 *
 * Tenant provisioning flow:
 * 1. Admin creates tenant via admin-portal UI
 * 2. provision-tenant Lambda creates:
 *    - Cognito UserPool
 *    - Cognito clients
 *    - Per-tenant DDB tables
 *    - Config files (awsconfig_<tenantId>.json, branding_<tenantId>.json)
 * 3. Tenant instantly available at <tenantId>.example.com
 */
/**
 * Tenant configuration interface
 *
 * This interface is kept for backward compatibility with existing code
 * that may reference TenantConfig, but is no longer used for CDK deployment.
 */
export interface TenantConfig {
    awsaccount: string | undefined;
    region: string | undefined;
    tenantId: string;
    tenantName: string;
    tenantAuthToken: string | undefined;
    mobileTokenKey: string | undefined;
    providerId: string | undefined;
    mobileTokenSalt: string | undefined;
    asmSalt: string | undefined;
    recaptchaKey: string | undefined;
    recaptchaSecret: string | undefined;
    smtpHost: string | undefined;
    smtpUser: string | undefined;
    smtpPass: string | undefined;
    smtpSecure: string | undefined;
    smtpPort: string | undefined;
    spPortalUrl: string;
    callbackUrls: string[];
    logoutUrls: string[];
    magicstring: string;
}
/**
 * Export empty tenant configuration array
 *
 * This signals to the CDK stack that:
 * - NO tenant-specific resources should be created
 * - Only SHARED infrastructure (DDB tables, API Gateway, etc.) should be deployed
 * - Tenants will be provisioned at runtime via provision-tenant Lambda
 *
 * Benefits:
 * - Instant tenant provisioning (no CDK redeploy)
 * - Scalable (no CloudFormation limits)
 * - True multi-tenancy (shared infrastructure)
 * - Cost-effective (no per-tenant CloudFront, S3, etc.)
 */
export declare const config: TenantConfig[];
