#!/usr/bin/env bash
# W13: print the OIDC parameters the ASM portal operator needs to let admins
# sign in through the aPersona Identity admin user pool.
#
# Reads the deployed SSO-CUPStack outputs and the AsmPortalSsoClient. The
# client secret is masked unless --with-secret is given; hand it over out of
# band, never in a ticket or email body.
#
# Usage (on the install host, with the deployment's AWS credentials):
#   scripts/asm-sso-params.sh [--with-secret] [--region us-east-1] [--stack SSO-CUPStack]
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
STACK="SSO-CUPStack"
WITH_SECRET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-secret) WITH_SECRET=1 ;;
    --region) REGION="$2"; shift ;;
    --stack) STACK="$2"; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

outputs=$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs' --output json)
out() { jq -r --arg k "$1" '.[] | select(.OutputKey == $k) | .OutputValue' <<<"$outputs"; }

client_id=$(out AsmPortalSsoClientId)
if [[ -z "$client_id" ]]; then
  echo "No AsmPortalSsoClient in $STACK. Set asm.ssoCallbackUrls in tenants-config.json and redeploy (update.sh)." >&2
  exit 1
fi
pool_id=$(out AdminPortalUserPoolId)
issuer=$(out AsmPortalSsoIssuer)
authorize=$(out AsmPortalSsoAuthorizeUrl)
token=$(out AsmPortalSsoTokenUrl)
hosted="${authorize%/oauth2/authorize}"

client=$(aws cognito-idp describe-user-pool-client --user-pool-id "$pool_id" --client-id "$client_id" \
  --region "$REGION" --query 'UserPoolClient' --output json)
secret=$(jq -r '.ClientSecret' <<<"$client")
if [[ $WITH_SECRET -eq 0 ]]; then secret="(masked; re-run with --with-secret)"; fi

cat <<EOF
# aPersona Identity -> ASM portal OIDC parameters (W13)
Issuer:            $issuer
Discovery:         $issuer/.well-known/openid-configuration
JWKS:              $issuer/.well-known/jwks.json
Authorize:         $authorize
Token:             $token
UserInfo:          $hosted/oauth2/userInfo
End session:       $hosted/logout
Client ID:         $client_id
Client secret:     $secret
Grant / scopes:    authorization_code; openid email profile
Redirect URIs:     $(jq -r '.CallbackURLs | join(", ")' <<<"$client")
Logout URIs:       $(jq -r '(.LogoutURLs // []) | join(", ")' <<<"$client")
Token auth method: client_secret_basic (client_secret_post also accepted)
Identity claims:   sub, email, email_verified, cognito:groups (SA / SPA_<org> / TA_<tenant>)
EOF
