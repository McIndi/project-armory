"""Authentication method tests (vault-config/ module output)."""


def test_vault_token_is_authenticated(vault_client):
    assert vault_client.is_authenticated()


def test_approle_mount_exists(vault_client):
    methods = vault_client.sys.list_auth_methods()["data"]
    assert "approle/" in methods


def test_approle_mount_type(vault_client):
    methods = vault_client.sys.list_auth_methods()["data"]
    assert methods["approle/"]["type"] == "approle"
