import { Certificate } from "aws-cdk-lib/aws-certificatemanager";
import { ARecord, PublicHostedZone } from "aws-cdk-lib/aws-route53";
import { Distribution } from "aws-cdk-lib/aws-cloudfront";
import { Construct } from "constructs";
export declare class WebApplication {
    scope: Construct;
    domainName: string;
    certificate: Certificate;
    hostedZone: PublicHostedZone;
    aRecord: ARecord;
    distribution: Distribution;
    tenantId: string;
    accountId: string | undefined;
    type: string;
    recaptchaKey: string | undefined;
    userPoolId: string | undefined;
    userPoolClientId: string | undefined;
    oauthDomain: string | undefined;
    constructor(scope: Construct, certificate: Certificate, hostedZone: PublicHostedZone, tenantId: string | undefined, accountId: string | undefined, isSPPortal: boolean, recaptchaKey?: string | undefined, userPoolId?: string | undefined, userPoolClientId?: string | undefined, oauthDomain?: string | undefined);
    private createS3Bucket;
    private createDistribution;
    private createRoute53ARecord;
}
