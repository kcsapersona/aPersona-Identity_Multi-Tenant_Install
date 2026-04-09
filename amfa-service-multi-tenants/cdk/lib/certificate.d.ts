import { Stack, StackProps } from "aws-cdk-lib";
import { Construct } from "constructs";
import { Certificate } from "aws-cdk-lib/aws-certificatemanager";
import { PublicHostedZone, IHostedZone } from "aws-cdk-lib/aws-route53";
/**
 * Stack for creating tenant-specific subdomain certificates (e.g., tenant1.rootdomain.com)
 * Creates a new hosted zone for the tenant subdomain and delegates it from the root zone
 */
export declare class TenantCertificateStack extends Stack {
    readonly tenantCertificate?: Certificate;
    readonly tenantHostedZone: PublicHostedZone;
    constructor(scope: Construct, id: string, props: StackProps, tenantId: string);
}
/**
 * Stack for creating the shared API certificate (e.g., api.rootdomain.com)
 * Uses the existing root hosted zone for DNS validation
 */
export declare class ApiCertificateStack extends Stack {
    readonly apiCertificate: Certificate;
    readonly rootHostedZone: IHostedZone;
    constructor(scope: Construct, id: string, props: StackProps);
}
/**
 * Stack for creating root wildcard certificate (*.rootdomain.com)
 * Used by AMFA Service for tenant subdomains (e.g., tenant1.rootdomain.com)
 */
export declare class RootWildcardCertificateStack extends Stack {
    readonly wildcardCertificate: Certificate;
    readonly rootHostedZone: IHostedZone;
    constructor(scope: Construct, id: string, props: StackProps);
}
/**
 * Stack for creating login subdomain wildcard certificate (*.login.rootdomain.com)
 * Used by SP Portal for tenant login subdomains (e.g., tenant1.login.rootdomain.com)
 */
export declare class LoginWildcardCertificateStack extends Stack {
    readonly loginWildcardCertificate: Certificate;
    readonly rootHostedZone: IHostedZone;
    constructor(scope: Construct, id: string, props: StackProps);
}
/**
 * Stack for creating idapersona subdomain wildcard certificate (*.idapersona.rootdomain.com)
 * Used by AMFA Service for tenant subdomains (e.g., tenant1.idapersona.rootdomain.com)
 */
export declare class IdaPersonaWildcardCertificateStack extends Stack {
    readonly idaPersonaWildcardCertificate: Certificate;
    readonly rootHostedZone: IHostedZone;
    constructor(scope: Construct, id: string, props: StackProps);
}
