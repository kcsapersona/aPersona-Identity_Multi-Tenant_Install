import { Secret } from "aws-cdk-lib/aws-secretsmanager";
import { Construct } from "constructs";
export declare class AmfaSecrets {
    scope: Construct;
    tenantId: string;
    secret: Secret;
    asmSecret: Secret;
    smtpSecret: Secret;
    constructor(scope: Construct, tenantId: string, tenantAuthToken: string | undefined, mobileTokenSalt: string | undefined, mobileTokenKey: string | undefined, providerId: string | undefined, asmSalt: string | undefined, smtpHost: string | undefined, smtpUser: string | undefined, smtpPass: string | undefined, smtpPort: string | undefined, smtpSecure: string | undefined);
    private createSmtpSecret;
    private createAsmSecret;
    private createSecret;
}
