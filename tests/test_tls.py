"""Bootstrap TLS certificate validation (vault/ module output)."""
import ssl
import socket
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.backends import default_backend

TLS_DIR = Path("/opt/armory/vault/tls")


def _load_cert(path):
    """Load the first PEM certificate from a file (handles chains)."""
    pem = Path(path).read_bytes()
    end = b"-----END CERTIFICATE-----"
    idx = pem.index(end) + len(end)
    return x509.load_pem_x509_certificate(pem[:idx], default_backend())


# ---------------------------------------------------------------------------
# CA certificate
# ---------------------------------------------------------------------------

def test_ca_cert_is_ca(vault_env):
    cert = x509.load_pem_x509_certificate(
        (TLS_DIR / "ca.crt").read_bytes(), default_backend()
    )
    bc = cert.extensions.get_extension_for_class(x509.BasicConstraints)
    assert bc.value.ca is True


def test_ca_cert_cn(vault_env):
    cert = x509.load_pem_x509_certificate(
        (TLS_DIR / "ca.crt").read_bytes(), default_backend()
    )
    cn = cert.subject.get_attributes_for_oid(x509.NameOID.COMMON_NAME)[0].value
    assert cn == "Armory Vault CA"


# ---------------------------------------------------------------------------
# Server certificate SANs
# ---------------------------------------------------------------------------

def test_server_cert_dns_sans(vault_env):
    cert = _load_cert(TLS_DIR / "vault.crt")
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    dns_names = san.value.get_values_for_type(x509.DNSName)
    assert "localhost" in dns_names
    assert "armory-vault" in dns_names


def test_server_cert_ip_san(vault_env):
    cert = _load_cert(TLS_DIR / "vault.crt")
    san = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
    ip_addresses = [str(ip) for ip in san.value.get_values_for_type(x509.IPAddress)]
    assert "127.0.0.1" in ip_addresses


# ---------------------------------------------------------------------------
# Chain validation
# ---------------------------------------------------------------------------

def test_server_cert_signed_by_ca(vault_env):
    ca_cert = x509.load_pem_x509_certificate(
        (TLS_DIR / "ca.crt").read_bytes(), default_backend()
    )
    server_cert = _load_cert(TLS_DIR / "vault.crt")
    assert server_cert.issuer == ca_cert.subject


# ---------------------------------------------------------------------------
# Live TLS handshake
# ---------------------------------------------------------------------------

def test_tls_handshake_version(vault_env):
    ctx = ssl.create_default_context(cafile=str(TLS_DIR / "ca.crt"))
    with socket.create_connection(("127.0.0.1", 8200), timeout=5) as sock:
        with ctx.wrap_socket(sock, server_hostname="127.0.0.1") as ssock:
            assert ssock.version() in ("TLSv1.2", "TLSv1.3")
