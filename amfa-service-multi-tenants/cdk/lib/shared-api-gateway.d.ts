import { RestApi, CorsOptions } from "aws-cdk-lib/aws-apigateway";
import { Function, LayerVersion } from "aws-cdk-lib/aws-lambda";
import { Table } from "aws-cdk-lib/aws-dynamodb";
import { Certificate } from "aws-cdk-lib/aws-certificatemanager";
import { IHostedZone } from "aws-cdk-lib/aws-route53";
import { Vpc, CfnEIP } from "aws-cdk-lib/aws-ec2";
import { Construct } from "constructs";
import { AmfaServcieDDB } from "./dynamodb";
import { AmfaSecrets } from "./secretmanager";
export declare class SharedApiGateway extends Construct {
    account: string | undefined;
    region: string | undefined;
    api: RestApi;
    configTable: Table;
    tenantTable: Table;
    certificate: Certificate;
    hostedZone: IHostedZone;
    vpc: Vpc;
    allTenantSecrets: {
        [tenantId: string]: AmfaSecrets;
    };
    allTenantUserPools: {
        [tenantId: string]: any;
    };
    CorsPreflightOptions: CorsOptions;
    eip: CfnEIP;
    customAuthorizer: Function;
    tenantUtilsLayer: LayerVersion;
    constructor(scope: Construct, id: string, certificate: Certificate, hostedZone: IHostedZone, account: string | undefined, region: string | undefined, sharedDDB: AmfaServcieDDB, allTenantSecrets: {
        [tenantId: string]: AmfaSecrets;
    }, allTenantUserPools: {
        [tenantId: string]: any;
    });
    private createApiGateway;
    private createTenantUtilsLayer;
    private createVpc;
    private createCustomAuthorizer;
    private createSharedLambda;
    /**
     * Create the token exchange Lambda (Python runtime).
     * This lambda handles /oauth2/token endpoint for OIDC token exchange.
     * It uses the per-tenant authcode DynamoDB tables.
     */
    private createTokenLambda;
    private createSharedEndpoints;
    private attachLambdaToApiGW;
}
