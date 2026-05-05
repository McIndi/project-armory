server.host: 0.0.0.0
server.port: 5601
opensearch.hosts: https://wazuh-indexer.armory.internal:9200
opensearch.ssl.verificationMode: full
opensearch.requestHeadersAllowlist: [ authorization, securitytenant, x-forwarded-for, x-forwarded-user, x-forwarded-groups, x-proxy-user, x-proxy-roles, x-auth-request-user, x-auth-request-groups ]
opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
# Proxy authentication via oauth2-proxy — trust X-Forwarded-User header from oauth2-proxy
# auth.type must be "proxy" for this Wazuh dashboard build.
# The proxycache block still configures which incoming headers carry identity.
opensearch_security.auth.type: "proxy"
opensearch_security.proxycache.user_header: "x-forwarded-user"
opensearch_security.proxycache.roles_header: "x-forwarded-groups"
# proxy_header_ip is required by the schema when auth.type=proxycache; used as fallback XFF value
opensearch_security.proxycache.proxy_header_ip: "127.0.0.1"
# Vault-issued cert for the dashboard HTTPS listener.
# Combined cert+CA+key PEM rendered by the Vault Agent sidecar.
server.ssl.enabled: true
server.ssl.key: "/vault/certs/dashboard.pem"
server.ssl.certificate: "/vault/certs/dashboard.pem"
# Full Armory CA bundle — used as the canonical trust anchor for all service TLS.
opensearch.ssl.certificateAuthorities: ["/vault/ca-bundle.pem"]
opensearch.ssl.certificate: "/vault/certs/dashboard.pem"
opensearch.ssl.key: "/vault/certs/dashboard.pem"
opensearch.ssl.alwaysPresentCertificate: true
uiSettings.overrides.defaultRoute: /app/wz-home
