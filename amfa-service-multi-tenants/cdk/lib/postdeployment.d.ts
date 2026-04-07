import { Construct } from 'constructs';
import { Table } from 'aws-cdk-lib/aws-dynamodb';
export declare const createPostDeploymentLambda: (scope: Construct, configTable: Table, tenantTable: Table, region: string | undefined, tenantUserPools: {
    [tenantId: string]: any;
}) => void;
