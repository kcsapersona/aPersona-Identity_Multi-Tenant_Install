import { Stack, StackProps } from "aws-cdk-lib";
import { Certificate } from "aws-cdk-lib/aws-certificatemanager";
import { IHostedZone } from "aws-cdk-lib/aws-route53";
import { Construct } from "constructs";
/**
 * Properties for the AMFA Stack
 */
export interface AmfaStackProps extends StackProps {
    /** Certificate for the shared API Gateway */
    apiCertificate: Certificate;
    /** Hosted zone for the shared API Gateway */
    apiHostedZone: IHostedZone;
    /** Root wildcard certificate (*.rootdomain.com) - kept for backward compatibility */
    rootWildcardCertificate: Certificate;
    /** Login wildcard certificate (*.login.rootdomain.com) for SP Portal */
    loginWildcardCertificate: Certificate;
    /** IdaPersona wildcard certificate (*.idapersona.rootdomain.com) for AMFA Service */
    idaPersonaWildcardCertificate: Certificate;
    /**
     * Tenant certificate stacks - kept for backward compatibility
     * but not used in shared infrastructure mode
     */
    tenantCertStacks?: {
        [tenantId: string]: any;
    };
}
/**
 * Main stack for the AMFA (Amazon Multi-Factor Authentication) application.
 *
 * NEW ARCHITECTURE: Shared Infrastructure Only
 * ============================================
 *
 * This stack now deploys ONLY shared infrastructure:
 * - Shared DynamoDB tables (tenant table + config table)
 * - Shared API Gateway
 * - Shared authentication Lambdas
 * - Post-deployment Lambda
 *
 * Tenant-specific resources are NO LONGER created by CDK.
 * Instead, they are provisioned at RUNTIME via the provision-tenant Lambda:
 * - Cognito UserPools (per tenant)
 * - Cognito clients (SAML + OAuth)
 * - Per-tenant DDB tables (authcode, sessionid, etc.)
 * - Config files (awsconfig_<tenantId>.json, branding_<tenantId>.json)
 *
 * Benefits:
 * - Instant tenant provisioning (~2 minutes vs 20-30 minutes)
 * - No CDK redeployment needed for new tenants
 * - Scalable (no CloudFormation limits)
 * - Cost-effective (shared CloudFront, S3, etc.)
 */
export declare class AmfaStack extends Stack {
    private readonly sharedDDB;
    private readonly rootDomainName;
    constructor(scope: Construct, id: string, props: AmfaStackProps);
    /**
     * Gets the root domain name from config file
     * @returns Root domain name string
     */
    private getRootDomainName;
    /**
     * Initializes shared DynamoDB tables for all tenants
     * @param props - Stack properties
     * @returns AmfaServcieDDB instance with shared tables
     */
    private initializeSharedResources;
    /**
     * Creates shared Lambda functions used by all tenants for authentication challenges
     * @returns Object containing the shared authentication Lambda functions
     */
    private createSharedAuthLambdas;
    /**
     * Creates the shared API Gateway used by all tenants
     * @param props - Stack properties
     */
    private createSharedApiGateway;
    /**
     * Creates post-deployment Lambda function
     * In shared infrastructure mode, this Lambda has a simplified role
     * @param props - Stack properties
     */
    private createPostDeploymentResources;
    /**
     * Creates shared AMFA service UI infrastructure
     * @param props - Stack properties
     */
    private createSharedAmfaServiceUI;
    /**
     * Creates shared SP Portal UI infrastructure
     * @param props - Stack properties
     */
    private createSharedSPPortalUI;
    /**
     * Creates a shared KMS key for Cognito Custom Email Sender
     * One key for all tenant UserPools
     */
    private createSharedCustomSenderKey;
    /**
     * Creates a shared custom email sender Lambda for all tenants
     * Looks up per-tenant SMTP settings at runtime
     */
    private createSharedCustomEmailSenderLambda;
    /**
     * Export Lambda ARNs and KMS key ARN to SSM Parameter Store
     * These are consumed by the admin portal's provision-tenant Lambda
     */
    private exportLambdaArnsToSSM;
    /**
     * Creates CloudFormation outputs for the stack
     */
    private createStackOutputs;
}
