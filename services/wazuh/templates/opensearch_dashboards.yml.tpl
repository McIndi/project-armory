server.host: 0.0.0.0
server.port: 5601
opensearch.hosts: https://wazuh-indexer.armory.internal:9200
opensearch.ssl.verificationMode: full
opensearch.requestHeadersAllowlist: [ authorization, securitytenant, x-remote-user, x-auth-request-user, x-remote-groups, x-auth-request-groups ]
opensearch_security.multitenancy.enabled: false
opensearch_security.readonly_mode.roles: ["kibana_read_only"]
# Proxy authentication via oauth2-proxy — trust X-Remote-User header from oauth2-proxy
opensearch_security.auth.type: "proxy"
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
