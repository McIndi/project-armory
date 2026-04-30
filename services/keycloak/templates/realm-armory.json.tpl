{
  "id": "${keycloak_realm}",
  "realm": "${keycloak_realm}",
  "displayName": "Armory",
  "enabled": true,
  "sslRequired": "external",
  "registrationAllowed": false,
  "loginWithEmailAllowed": false,
  "duplicateEmailsAllowed": false,
  "resetPasswordAllowed": false,
  "editUsernameAllowed": false,
  "bruteForceProtected": true,

  "groups": [
    {
      "id": "aaaaaaaa-1001-1001-1001-000000000001",
      "name": "${realm_required_group}",
      "path": "/${realm_required_group}",
      "subGroups": []
    },
    {
      "id": "aaaaaaaa-1001-1001-1001-000000000002",
      "name": "${wazuh_required_group}",
      "path": "/${wazuh_required_group}",
      "subGroups": []
    }
  ],

  "users": [
    {
      "id": "bbbbbbbb-1001-1001-1001-000000000001",
      "username": "${realm_operator_username}",
      "enabled": true,
      "emailVerified": false,
      "credentials": [
        {
          "type": "password",
          "value": "${realm_operator_password}",
          "temporary": false
        }
      ],
      "groups": [
        "/${realm_required_group}"
      ]
    },
    {
      "id": "bbbbbbbb-1001-1001-1001-000000000002",
      "username": "${wazuh_operator_username}",
      "enabled": true,
      "emailVerified": false,
      "credentials": [
        {
          "type": "password",
          "value": "${wazuh_operator_password}",
          "temporary": false
        }
      ],
      "groups": [
        "/${wazuh_required_group}"
      ]
    }
  ],

  "clients": [
    {
      "id": "cccccccc-1001-1001-1001-000000000001",
      "clientId": "${vault_oidc_client_id}",
      "name": "Vault OIDC Client",
      "description": "Confidential OIDC client for Vault operator login (CLI and UI)",
      "enabled": true,
      "publicClient": false,
      "secret": "${vault_oidc_client_secret}",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "protocol": "openid-connect",
      "redirectUris": ${jsonencode(vault_oidc_redirect_uris)},
      "webOrigins": [],
      "attributes": {
        "post.logout.redirect.uris": "+"
      },
      "protocolMappers": [
        {
          "id": "dddddddd-1001-1001-1001-000000000001",
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }
      ]
    },
    {
      "id": "eeeeeeee-1001-1001-1001-000000000001",
      "clientId": "${agent_cli_client_id}",
      "name": "Agent CLI OIDC Client",
      "description": "Public OIDC client for agent CLI PKCE interactive login",
      "enabled": true,
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "protocol": "openid-connect",
      "redirectUris": ["${agent_cli_redirect_uri}"],
      "webOrigins": ["${agent_cli_web_origin}"],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "+"
      },
      "protocolMappers": [
        {
          "id": "ffffffff-1001-1001-1001-000000000001",
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }
      ]
    },
    {
      "id": "99999999-1001-1001-1001-000000000001",
      "clientId": "${wazuh_oidc_client_id}",
      "name": "Wazuh Dashboard OIDC Client",
      "description": "Confidential OIDC client for Wazuh oauth2-proxy login",
      "enabled": true,
      "publicClient": false,
      "secret": "${wazuh_oidc_client_secret}",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "authorizationServicesEnabled": false,
      "protocol": "openid-connect",
      "redirectUris": ["${wazuh_redirect_uri}"],
      "webOrigins": ["${wazuh_web_origin}"],
      "attributes": {
        "post.logout.redirect.uris": "+"
      },
      "protocolMappers": [
        {
          "id": "99999999-1001-1001-1001-000000000002",
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "consentRequired": false,
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "userinfo.token.claim": "true"
          }
        }
      ]
    }
  ]
}
