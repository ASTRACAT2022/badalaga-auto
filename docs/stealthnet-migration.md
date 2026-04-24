# StealthNet -> Bedolaga migration script

This repository now includes a safety-first migration helper:

- `scripts/migrate_stealthnet_to_bedolaga.sh`
- `scripts/sql/stealthnet_to_bedolaga.sql`

## What it does

1. Creates a staging PostgreSQL database.
2. Restores your StealthNet SQL dump into staging.
3. Archives **all source rows** into `legacy_stealthnet.raw_rows`.
4. Migrates core entities into Bedolaga tables:
   - `clients -> users`
   - `promo_groups -> promo_groups`
   - `tariffs -> tariffs`
   - `secondary_subscriptions -> subscriptions`
   - `payments -> transactions`
   - `tickets -> tickets`
   - `ticket_messages -> ticket_messages`
   - `promo_codes -> promocodes`
   - `promo_code_usages -> promocode_uses`
   - `promo_activations -> user_promo_groups`
   - `system_settings -> system_settings` (with `legacy_stealthnet__` key prefix)
5. Writes logs and summary under `data/migrations/stealthnet/<timestamp>/`.

## Safety defaults

- Default mode is **dry-run** (everything is rolled back).
- Real changes require `--apply`.
- In `--apply`, a pre-migration `pg_dump` backup is created (unless `--no-backup`).
- Subscription import mode defaults to `expired` to avoid accidental active access.

## Run

Dry-run first:

```bash
scripts/migrate_stealthnet_to_bedolaga.sh \
  --dump stealthnet-backup-2026-04-24T06-18-24.sql
```

Apply for real:

```bash
scripts/migrate_stealthnet_to_bedolaga.sh \
  --dump stealthnet-backup-2026-04-24T06-18-24.sql \
  --apply --yes
```

If you explicitly want imported subscriptions as active/pending:

```bash
scripts/migrate_stealthnet_to_bedolaga.sh \
  --dump stealthnet-backup-2026-04-24T06-18-24.sql \
  --apply --subs-mode active --yes
```

## Notes

- Requires a running PostgreSQL container (default: `remnawave_bot_db`).
- Defaults assume:
  - DB user: `remnawave_user`
  - target DB: `remnawave_bot`
- You can override via flags (`--pg-container`, `--pg-user`, `--target-db`).
