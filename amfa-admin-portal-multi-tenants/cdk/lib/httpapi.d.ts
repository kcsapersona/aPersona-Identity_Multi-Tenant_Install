import { Construct } from "constructs";
import { AppStackProps } from "./application";
import { Bucket } from "aws-cdk-lib/aws-s3";
import { HttpApi } from "aws-cdk-lib/aws-apigatewayv2";
import { HttpUserPoolAuthorizer, HttpLambdaAuthorizer } from "aws-cdk-lib/aws-apigatewayv2-authorizers";
import { Function } from "aws-cdk-lib/aws-lambda";
import { SSOUserPool } from "./userpool";
export declare class SSOApiGateway {
    scope: Construct;
    region: string | undefined;
    account: string | undefined;
    api: HttpApi;
    certificateArn: string;
    domainName: string;
    hostedUIDomain: string;
    hostedZoneId: string;
    authorizor: HttpUserPoolAuthorizer;
    multiTenantAuthorizor: HttpLambdaAuthorizer;
    totpTokenAuthorizor: HttpUserPoolAuthorizer;
    amfaBaseUrl: string;
    adminUserPoolId: string;
    importUsersWorkerLambda: Function;
    imoprtUsersJobsS3Bucket: Bucket;
    private _sharedVpcConfig;
    constructor(scope: Construct, props: AppStackProps);
    private createImportUsersWorkerLambda;
    attachAuthorizor(userPool: SSOUserPool): void;
    attachMetadataS3(s3bucket: Bucket): void;
    private userPoolIdToArn;
    private tableNameToArn;
    private createHttpApi;
    createAdminApiEndpoints(userPoolDomain: string, adminUserPoolId: string): void;
    private createTotpTokenLambda;
    createMultiTenantAuthorizer(): void;
    createEndUserPortalApiEndpoints(): void;
    private createServicePrvoiderLambda;
    private createUserCustomSPSLambda;
    /**
     * Import the shared VPC from the login service stack via SSM parameters.
     * Cached: CDK constructs are created once and reused by all samlgw2-calling lambdas.
     * This avoids duplicate construct ID errors when called multiple times.
     */
    private getSharedVpcConfig;
    private createAmfaSamlSpsLambda;
    private createAmfaTenantsLambda;
    private createFetchAmfaConfigLambda;
    private createOrganizationsLambda;
    /**
     * Base policy statements shared by ALL admin portal lambdas.
     * These are the minimum permissions needed by the admin-auth layer:
     * - Cognito: AdminListGroupsForUser, ListGroups (for RBAC in auth layer)
     * - DynamoDB: GetItem, Query on tenant table (for tenant resolution)
     * - SecretsManager: GetSecretValue for tenant secrets (auth layer)
     *
     * Individual lambdas get additional permissions via getResourceSpecificStatements().
     *
     * SECURITY (1.1): Replaces the previous wildcard policy (cognito-idp:*, dynamodb:*, s3:*, iam:PassRole).
     */
    private getBaseStatements;
    /**
     * Resource-specific policy statements for each Lambda type.
     * Returns additional permissions beyond the base statements.
     *
     * SECURITY (1.1): Least-privilege per resource type.
     */
    private getResourceSpecificStatements;
    private createLambda;
    /**
     * Create Platform Info Lambda (SA only)
     * Returns global platform information like NAT IP address.
     * Lambda internally checks SA role from JWT - non-SA users get 403.
     * Only needs SSM:GetParameter permission (least privilege).
     */
    private createPlatformInfoLambda;
    private createSmtpConfigLambda;
    private createSettingsLambda;
    private createBrandingLambda;
}
