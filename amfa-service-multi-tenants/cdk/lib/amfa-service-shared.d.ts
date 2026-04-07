import { Certificate } from "aws-cdk-lib/aws-certificatemanager";
import { ARecord, IHostedZone } from "aws-cdk-lib/aws-route53";
import { Bucket } from "aws-cdk-lib/aws-s3";
import { Distribution, OriginAccessIdentity } from "aws-cdk-lib/aws-cloudfront";
import { Construct } from "constructs";
/**
 * Properties for AmfaServiceShared construct
 */
export interface AmfaServiceSharedProps {
    /** Root domain name (e.g., example.com) */
    rootDomain: string;
    /** Wildcard certificate for *.rootDomain */
    certificate: Certificate;
    /** Hosted zone for the root domain */
    hostedZone: IHostedZone;
    /** AWS account ID */
    account: string | undefined;
    /** AWS region */
    region: string | undefined;
}
/**
 * Shared AMFA Service Infrastructure
 *
 * NEW ARCHITECTURE: Shared Multi-Tenant AMFA Service
 * ===================================================
 *
 * This construct creates a SINGLE shared infrastructure for ALL AMFA service tenants:
 *
 * 1. Single S3 bucket for static assets
 * 2. Single CloudFront distribution with wildcard domain (*.example.com)
 * 3. Wildcard DNS A record pointing all tenant subdomains to CloudFront
 *
 * Benefits:
 * - Cost: 80-90% reduction (1 CloudFront vs N CloudFronts)
 * - Instant tenant availability (no CDK redeploy needed)
 * - Simplified management (one deployment, all tenants updated)
 *
 * Config File Strategy:
 * --------------------
 * Each tenant has its own config file: awsconfig_<tenantId>.json
 * - Created by provision-tenant Lambda at runtime
 * - Contains tenant-specific recaptcha_key
 * - No default/fallback config
 *
 * Frontend automatically loads: /awsconfig_<tenantId>.json
 * (tenantId extracted from window.location.hostname)
 *
 * Example:
 * - tenant1.example.com → /awsconfig_tenant1.json
 * - tenant2.example.com → /awsconfig_tenant2.json
 */
export declare class AmfaServiceShared extends Construct {
    readonly s3bucket: Bucket;
    readonly distribution: Distribution;
    readonly originAccessIdentity: OriginAccessIdentity;
    readonly aRecord?: ARecord;
    constructor(scope: Construct, id: string, props: AmfaServiceSharedProps);
    /**
     * Creates the shared S3 bucket for all AMFA service tenants
     */
    private createS3Bucket;
    /**
     * Creates CloudFront distribution with custom domain *.idapersona.<rootDomain>
     *
     * Uses the IdaPersona wildcard certificate to serve all tenant subdomains:
     * - tenant1.idapersona.example.com
     * - tenant2.idapersona.example.com
     */
    private createDistribution;
    /**
     * Creates wildcard DNS A record pointing to CloudFront
     * Routes all *.idapersona.<rootDomain> to the shared CloudFront distribution
     */
    private createWildcardARecord;
    /**
     * Deploys static assets to S3
     *
     * IMPORTANT: This deployment does NOT include config files!
     * - Config files (awsconfig_<tenantId>.json) are created by provision-tenant Lambda
     * - prune: false ensures we don't delete tenant config files on redeployment
     */
    private deployStaticAssets;
}
