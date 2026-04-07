import { Table } from "aws-cdk-lib/aws-dynamodb";
import { Construct } from "constructs";
export declare class AmfaServcieDDB {
    scope: Construct;
    account: string | undefined;
    region: string | undefined;
    tenantId: string | undefined;
    authCodeTable?: Table;
    sessionIdTable?: Table;
    configTable?: Table;
    tenantTable?: Table;
    totpTokenTable?: Table;
    pwdHashTable?: Table;
    constructor(scope: Construct, account: string | undefined, region: string | undefined, tenantId: string | undefined, createSharedOnly?: boolean);
    private createAmfaConfigTable;
    private createAmfaTenantTable;
    private createAuthCodeTable;
    private createSessionIdTable;
    private createTotpTokenTable;
    private createPWDHashTable;
}
