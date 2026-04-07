import json
import os
import re

import boto3
from botocore.exceptions import ClientError
from boto3.dynamodb.conditions import Attr

AWS_REGION = os.environ.get("AWS_REGION")

# Authcode table name prefix — per-tenant tables follow pattern: amfa-authcode-{tenantId}
AUTHCODE_TABLE_PREFIX = "amfa-authcode-"


def extract_tenant_id_from_redirect_uri(redirect_uri):
    """
    Extract tenant ID from Cognito redirect_uri.

    The redirect_uri format is:
      https://{tenantId}-{hash}.auth.{region}.amazoncognito.com/oauth2/idpresponse

    The domain prefix is '{tenantId}-{hash}' where hash is a short base-36 string
    generated during provisioning. We split on '.auth.' to get the prefix,
    then remove the last '-{hash}' segment to get the tenantId.
    """
    try:
        # Extract hostname from URL
        # e.g., "tenantd-2zpjyb.auth.us-east-1.amazoncognito.com"
        hostname = redirect_uri.split("//")[1].split("/")[0]

        # Get the domain prefix before '.auth.'
        # e.g., "tenantd-2zpjyb"
        domain_prefix = hostname.split(".auth.")[0]

        # The hash is the last segment after the final '-'
        # e.g., "tenantd" from "tenantd-2zpjyb"
        last_dash_idx = domain_prefix.rfind("-")
        if last_dash_idx > 0:
            tenant_id = domain_prefix[:last_dash_idx]
            return tenant_id

        print(f"[Token] Could not parse tenant ID from domain prefix: {domain_prefix}")
        return None
    except Exception as e:
        print(f"[Token] Error extracting tenant ID from redirect_uri: {e}")
        return None


def handler(event, context):

    print(event)

    bodyStr = event["body"]
    code = ""
    clientId = ""
    clientSecret = ""
    redirectUri = ""

    for t in bodyStr.split("&"):
        param = t.split("=", 1)
        if param[0] == "code":
            code = param[1]
        elif param[0] == "client_secret":
            clientSecret = param[1]
        elif param[0] == "client_id":
            clientId = param[1]
        elif param[0] == "redirect_uri":
            redirectUri = param[1]
            # URL-decode the redirect_uri
            from urllib.parse import unquote

            redirectUri = unquote(redirectUri)

    # Extract tenant ID from redirect_uri to determine authcode table
    tenantId = extract_tenant_id_from_redirect_uri(redirectUri)

    if not tenantId:
        print("[Token] ERROR: Could not determine tenant ID")
        return {
            "statusCode": 400,
            "body": json.dumps("Could not determine tenant from request"),
        }

    DBTABLE_NAME = f"{AUTHCODE_TABLE_PREFIX}{tenantId}"
    print(f"[Token] Resolved tenant: {tenantId}, authcode table: {DBTABLE_NAME}")

    RESCODE = 200
    RESBODY = json.dumps("All Good!")

    dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)

    table = dynamodb.Table(DBTABLE_NAME)

    try:
        response = table.scan(FilterExpression=Attr("authCode").eq(code))
    except ClientError as e:
        print(e.response["Error"]["Message"])
        RESBODY = json.dumps(e.response["Error"]["Message"])
        RESCODE = 400
    else:
        print(response)
        if not response.get("Items") or len(response["Items"]) == 0:
            print(f"[Token] Auth code not found in table {DBTABLE_NAME}")
            RESBODY = json.dumps("Auth code not found")
            RESCODE = 400
        else:
            tokens = response["Items"][0]["tokenString"]
            username = response["Items"][0]["username"]
            apti = response["Items"][0]["apti"]
            table.delete_item(Key={"username": username, "apti": apti})

            RESCODE = response["ResponseMetadata"]["HTTPStatusCode"]
            RESBODY = tokens

    return {"statusCode": RESCODE, "body": RESBODY}
