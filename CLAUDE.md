# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash toolkit installing/updating/backing up/restoring Pterodactyl Panel + Wings on **Ubuntu 24.04 native** (target: Multipass instances on macOS/Windows). No PPAs — only official Ubuntu repos for PHP, MariaDB, Redis. Two topologies supported: panel+wings same instance, or wings on a remote instance talking to the panel's MariaDB.

Spec doc: `requeriments.md` (Spanish) — original requirements the implementation should stay aligned with. All in-code comments/messages are Spanish; keep new code consistent with that.

## Running / testing

No build step, no test suite — this is operational Bash meant to run against a live Ubuntu 24.04 root shell.

```bash
sudo bash install.sh        # interactive menu (local repo checkout)
sudo bash installer.sh       # thin wrapper, just execs install.sh
sudo bash <(curl -fsSL https://raw.githubusercontent.com/YamiKnigth/panel-installer/main/install.sh)  # remote one-liner
```

To exercise a single module directly (skipping the menu):
```bash
sudo bash scripts/install_panel.sh
sudo bash scripts/install_wings.sh
sudo bash scripts/backup.sh
sudo bash scripts/update_panel.sh
sudo bash scripts/update_wings.sh
sudo bash scripts/restore_backup.sh
```
Every script under `scripts/` sources `scripts/common.sh` and requires root. There's no mock/dry-run mode — validate changes against a real Multipass Ubuntu 24.04 VM before calling something done. `shellcheck` is worth running manually since there's no CI wired for it (note existing `# shellcheck disable=SC1090/SC1091` on dynamic `source` calls).

## Architecture

**`install.sh`** — menu loop. For each option it calls `ejecutar_modulo <script_name>`, which prefers a local `scripts/<name>` (when running from a clone) and otherwise downloads that module + `common.sh` fresh from GitHub raw into `/tmp/pterodactyl-installer` (this is how the curl-pipe one-liner stays a single file yet still gets the modular scripts). Keep this dual local/remote resolution in mind when adding a new module — it needs to work fetched standalone too.

**`scripts/common.sh`** — shared library sourced by every module. Key pieces:
- `RUNTIME_FILE` = `/etc/panel-installer/runtime.conf`: shell-sourceable state (panel URL, chosen IP, PHP version, DB creds) written by `install_panel.sh` via `save_runtime_config` and read back by other modules via `load_runtime_config`. This is how modules coordinate without re-deriving facts (e.g. Wings reusing the panel's DB password).
- `load_panel_db_credentials` — resolves DB creds with priority: panel's own `.env` > runtime.conf > hardcoded defaults.
- `choose_ip_interactively` / `collect_ip_candidates` — lists all global IPv4s (excluding docker/veth/br-/lo interfaces) and makes the user pick, since Multipass bridged networking often surfaces multiple interfaces and the "first IP" heuristic picks the wrong (isolated) one.
- `create_backup_archive` / `upload_backup_archive` — shared backup packaging (mysqldump + `.env` + Wings `config.yml` + `runtime.conf` → zip in `/tmp`) and upload to bashupload.com; reused by both `backup.sh` and the pre-update/pre-reinstall backup steps in `update_panel.sh`/`update_wings.sh`/`install_panel.sh`.
- `run_panel_mysql` / `run_panel_mysql_single` — thin `mysql` wrappers using resolved panel DB creds; `sql_escape` for manual SQL string interpolation (there's no parameterized-query layer — all SQL is built via string concatenation, so always route user input through `sql_escape`).
- PHP version handling (`detect_available_php_version`, `resolve_panel_php_version`, `php_fpm_service_name/socket_path`) prefers 8.3, falls back to 8.2 — never hardcode a PHP version elsewhere.

**Wings registration bypasses the panel's HTTP API entirely** (`scripts/install_wings.sh`): reverse-proxy setups return 404 on the panel API from a fresh node, so the script inserts directly into `nodes`/`allocations`/`locations` tables. Because Pterodactyl's `nodes.daemon_token`/`daemon_token_id` use Eloquent's `encrypted` cast (`Crypt::encryptString`/`decryptString`), the script needs ciphertext the panel can decrypt. It uses **two token-generation paths**, chosen by `use_local_crypto`:
  - **Local** (Wings installing onto the same instance as a local, filesystem-reachable panel — `$PANEL_DIR/vendor/autoload.php` present): boots the panel's real Laravel app (`require vendor/autoload.php` + `bootstrap/app.php` + kernel bootstrap) and calls the actual `Illuminate\Support\Facades\Crypt::encryptString/decryptString` — byte-exact against whatever Laravel/cipher version is actually installed, no hand-rolled crypto. Deliberately does **not** use `php artisan tinker`, since `--no-dev` panel installs may lack `psy/psysh`.
  - **Remote/fallback** (remote panel, or local panel missing vendor dir): a manual PHP reimplementation of `Illuminate\Encryption\Encrypter`'s payload format (`iv`/`value`/`mac`/`tag` base64-JSON), keyed by the panel's `APP_KEY`. Two format details previously got this wrong and broke every node ("MAC is invalid" on decrypt) — keep these correct if you touch it: the MAC is `hash_hmac('sha256', $iv.$value, $key)` as a **plain hex string** (no raw-binary flag, no base64-encoding it), and the value is **not** `serialize()`d before `openssl_encrypt` (the `encrypted` cast, unlike the generic `encrypt()` helper, skips serialization).
  - Both paths expose the same `encrypt_token`/`decrypt_token` shell functions so the DB-insert code downstream doesn't care which ran.
  - After encrypting, the script **round-trip verifies** (decrypt what it just encrypted, compare to plaintext) before touching the DB, and **again reads back what MySQL actually stored** (`SELECT daemon_token_id, daemon_token FROM nodes WHERE id = ...`) and compares byte-for-byte before proceeding — on any mismatch it deletes the just-inserted node/location rows and aborts, rather than leaving a broken node for the panel to trip over later. Preserve this gate if you refactor the insert flow.

Table inserts (`nodes`, `allocations`, `locations`) are built column-by-column via `append_*_field` helpers that check `SHOW COLUMNS` first (`node_column_exists` etc.) before adding a field — this tolerates schema drift across panel versions. Follow this pattern rather than hardcoding a column list when adding new inserted fields.

**Backups** are DB dump + config only, never full panel source or the Wings binary — restore assumes the base software is already (re)installed and only replays data/config (see `restore_backup.sh` and the "Nota importante" in README.md).

## Conventions to follow

- All user-facing strings/comments are Spanish — match this in new scripts/messages.
- `set -Eeuo pipefail` + an `ERR` trap logging `$LINENO`/`$BASH_COMMAND` at the top of every module — copy this pattern in new scripts.
- Color/logging helpers (`log_info`, `log_warn`, `log_error`, `log_success`) live in `common.sh` — use them instead of raw `echo`.
- Never `clear` the screen on failure paths — admins need scrollback to diagnose (explicit requirement in `requeriments.md`).
- Install PHP package lists explicitly one-by-one (`php8.3-fpm`, `php8.3-cli`, ...) — never brace-expansion (`php8.3-{cli,fpm}`), since some curl-piped shells silently drop expanded members.
