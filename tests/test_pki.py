"""PKI hierarchy and certificate issuance tests (vault-config/ module output)."""
from cryptography import x509
from cryptography.hazmat.backends import default_backend
from cryptography.x509.oid import ExtensionOID, NameOID


def _parse_cert(pem_str):
    return x509.load_pem_x509_certificate(pem_str.encode(), default_backend())


def _issue_internal(vault_client, cn="test.armory.internal"):
    return vault_client.secrets.pki.generate_certificate(
        name="armory-server",
        common_name=cn,
        mount_point="pki_int",
    )


def _issue_external(vault_client, cn="test.example.com"):
    return vault_client.secrets.pki.generate_certificate(
        name="armory-external",
        common_name=cn,
        mount_point="pki_ext",
    )


# ---------------------------------------------------------------------------
# Mounts exist
# ---------------------------------------------------------------------------

def test_pki_root_mount_exists(vault_client):
    mounts = vault_client.sys.list_mounted_secrets_engines()["data"]
    assert "pki/" in mounts


def test_pki_int_mount_exists(vault_client):
    mounts = vault_client.sys.list_mounted_secrets_engines()["data"]
    assert "pki_int/" in mounts


def test_pki_ext_mount_exists(vault_client):
    mounts = vault_client.sys.list_mounted_secrets_engines()["data"]
    assert "pki_ext/" in mounts


# ---------------------------------------------------------------------------
# Roles exist
# ---------------------------------------------------------------------------

def test_pki_int_role_exists(vault_client):
    roles = vault_client.secrets.pki.list_roles(mount_point="pki_int")
    assert "armory-server" in roles["data"]["keys"]


def test_pki_ext_role_exists(vault_client):
    roles = vault_client.secrets.pki.list_roles(mount_point="pki_ext")
    assert "armory-external" in roles["data"]["keys"]


# ---------------------------------------------------------------------------
# Internal CA issuance
# ---------------------------------------------------------------------------

def test_internal_cert_common_name(vault_client):
    resp = _issue_internal(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    cn = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert cn == "test.armory.internal"


def test_internal_cert_issuer_cn(vault_client):
    resp = _issue_internal(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    issuer_cn = cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert issuer_cn == "Armory Internal Intermediate CA"


def test_internal_cert_has_aia(vault_client):
    resp = _issue_internal(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    aia = cert.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_INFORMATION_ACCESS)
    assert aia is not None


def test_internal_cert_has_crl_dp(vault_client):
    resp = _issue_internal(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    crl = cert.extensions.get_extension_for_oid(ExtensionOID.CRL_DISTRIBUTION_POINTS)
    assert crl is not None


def test_internal_cert_chain_present(vault_client):
    resp = _issue_internal(vault_client)
    assert resp["data"]["issuing_ca"] or resp["data"]["ca_chain"]


# ---------------------------------------------------------------------------
# External CA issuance
# ---------------------------------------------------------------------------

def test_external_cert_common_name(vault_client):
    resp = _issue_external(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    cn = cert.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert cn == "test.example.com"


def test_external_cert_issuer_cn(vault_client):
    resp = _issue_external(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    issuer_cn = cert.issuer.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value
    assert issuer_cn == "Armory External Intermediate CA"


def test_external_cert_has_aia(vault_client):
    resp = _issue_external(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    aia = cert.extensions.get_extension_for_oid(ExtensionOID.AUTHORITY_INFORMATION_ACCESS)
    assert aia is not None


def test_external_cert_has_crl_dp(vault_client):
    resp = _issue_external(vault_client)
    cert = _parse_cert(resp["data"]["certificate"])
    crl = cert.extensions.get_extension_for_oid(ExtensionOID.CRL_DISTRIBUTION_POINTS)
    assert crl is not None


# ---------------------------------------------------------------------------
# Key uniqueness — Vault generates fresh keys, never replays
# ---------------------------------------------------------------------------

def test_private_key_not_reused(vault_client):
    r1 = _issue_internal(vault_client)
    r2 = _issue_internal(vault_client)
    assert r1["data"]["private_key"] != r2["data"]["private_key"]
