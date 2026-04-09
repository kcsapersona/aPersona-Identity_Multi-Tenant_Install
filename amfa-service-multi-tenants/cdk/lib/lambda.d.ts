import { Construct } from 'constructs';
import { Function, Runtime } from 'aws-cdk-lib/aws-lambda';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';
import { Table } from 'aws-cdk-lib/aws-dynamodb';
import { Secret } from 'aws-cdk-lib/aws-secretsmanager';
export declare const BasicLambdaPolicyStatement: PolicyStatement;
export declare const getOAuthLambdaPolicy: (oAuthEndpointName: string) => PolicyStatement[];
export declare const createAuthChallengeFn: (scope: Construct, lambdaName: string, runtime: Runtime) => Function;
export declare const createCustomEmailSenderLambda: (scope: Construct, configTable: Table, tenantId: string, spPortalUrl: string, smtpScrets: Secret) => Function;
/**
 * Creates a SHARED custom email sender Lambda for ALL tenants.
 *
 * Unlike the per-tenant version above, this Lambda:
 * - Is created once and shared across all tenant UserPools
 * - Looks up tenant-specific SMTP settings at runtime from config DDB table
 * - Extracts tenantId from the Cognito trigger event (userPoolId → tenant mapping)
 *
 * @param scope - CDK construct scope
 * @param configTable - Shared config DDB table
 * @param tenantTable - Shared tenant DDB table (for UserPool → tenant mapping)
 * @returns Lambda Function
 */
export declare const createSharedCustomEmailSenderLambda: (scope: Construct, configTable: Table, tenantTable: Table) => Function;
