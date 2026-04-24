# Auto Bootstrap: Bot + Cabinet + StealthNet Import

Script: `scripts/bootstrap_bedolaga_stack.sh`

## What it does

- Prepares/updates bot `.env` and cabinet `.env`
- Validates critical config (bot token, admins, RemnaWave, enabled payments)
- Starts bot stack (`docker compose up` in project root)
- Starts cabinet stack (`docker compose up` in `bedolaga-cabinet-main`)
- Cabinet runs on port `7053` by default
- Optionally auto-imports StealthNet dump from `./backups`

## Fast start

```bash
scripts/bootstrap_bedolaga_stack.sh --apply --yes --bot-username YOUR_BOT_USERNAME
```

## Auto-import StealthNet backup

1. Put your dump into `./backups`, for example:
   - `backups/stealthnet-backup-2026-04-24T06-18-24.sql`
2. Run:

```bash
scripts/bootstrap_bedolaga_stack.sh \
  --apply --yes \
  --bot-username YOUR_BOT_USERNAME \
  --import-stealthnet on
```

By default migration imports subscriptions as `expired` (safe mode).
If you need active/pending mapping:

```bash
scripts/bootstrap_bedolaga_stack.sh \
  --apply --yes \
  --bot-username YOUR_BOT_USERNAME \
  --import-stealthnet on \
  --stealthnet-subs-mode active
```

## Useful options

- `--cabinet-port 7053`
- `--api-port 8080`
- `--providers yookassa,cryptobot`
- `--backups-dir ./backups`
- `--stealthnet-dump /path/to/file.sql`
- `--skip-build`

## Dry-run validation only

```bash
scripts/bootstrap_bedolaga_stack.sh
```

This checks config but does not start containers.
