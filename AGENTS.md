# Contributor instructions

Use fictional data and temporary directories for tests. Never use a real login, Keychain, account folder or conversation as a fixture. Builds do not authorize installation, service registration or a live network failure test. Keep launch/switch gates fail-closed and keep default CLI login checks distinct from running CLI process ownership. Preserve upstream MIT notices.
