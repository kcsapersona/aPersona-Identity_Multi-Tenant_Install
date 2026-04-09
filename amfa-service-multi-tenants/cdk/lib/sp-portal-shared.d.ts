import { Construct } from 'constructs';
import { Bucket } from 'aws-cdk-lib/aws-s3';
import { Distribution, OriginAccessIdentity } from 'aws-cdk-lib/aws-cloudfront';
import { IHostedZone } from 'aws-cdk-lib/aws-route53';
import { ICertificate } from 'aws-cdk-lib/aws-certificatemanager';
export interface SPPortalSharedProps {
    /**
     * Root domain name (e.g., example.com)
     * Tenants will be accessed at <tenantId>.login.example.com
     */
    rootDomain: string;
    /**
     * Route53 hosted zone for DNS
     */
    hostedZone: IHostedZone;
    /**
     * Wildcard SSL certificate for *.login.example.com
     */
    certificate: ICertificate;
    /**
     * Path to SP portal static assets
     */
    assetsPath?: string;
    /**
     * AWS region
     */
    region: string;
    /**
     * AWS account ID
     */
    account: string;
}
/**
 * Shared SP Portal Infrastructure for Multi-Tenant Access
 *
 * This construct creates:
 * 1. Single S3 bucket for all tenant SP portal files
 * 2. Single CloudFront distribution with wildcard domain (*.login.example.com)
 * 3. Wildcard DNS record to route all login subdomains to CloudFront
 *
 * Each tenant gets:
 * - URL: <tenantId>.login.example.com
 * - Config files: awsconfig_<tenantId>.json, branding_<tenantId>.json
 *
 * The SP portal dynamically loads configuration based on the subdomain.
 */
export declare class SPPortalShared extends Construct {
    readonly s3bucket: Bucket;
    readonly distribution: Distribution;
    readonly originAccessIdentity: OriginAccessIdentity;
    constructor(scope: Construct, id: string, props: SPPortalSharedProps);
    /**
     * Get the CloudFront distribution URL
     */
    getDistributionUrl(): string;
    /**
     * Get tenant-specific URL
     */
    getTenantUrl(tenantId: string, rootDomain: string): string;
}
