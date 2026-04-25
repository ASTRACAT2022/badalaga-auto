\set ON_ERROR_STOP on

\echo '[phase] init migration schemas'
CREATE EXTENSION IF NOT EXISTS dblink;

CREATE SCHEMA IF NOT EXISTS migration_stealthnet;
CREATE SCHEMA IF NOT EXISTS legacy_stealthnet;

CREATE TABLE IF NOT EXISTS legacy_stealthnet.raw_rows (
    id bigserial PRIMARY KEY,
    source_db text NOT NULL,
    source_table text NOT NULL,
    source_pk text,
    row_data jsonb NOT NULL,
    imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ix_legacy_raw_rows_source_table ON legacy_stealthnet.raw_rows(source_table);
CREATE INDEX IF NOT EXISTS ix_legacy_raw_rows_source_pk ON legacy_stealthnet.raw_rows(source_pk);

CREATE TABLE IF NOT EXISTS migration_stealthnet.client_map (
    source_client_id text PRIMARY KEY,
    target_user_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.promo_group_map (
    source_promo_group_id text PRIMARY KEY,
    target_promo_group_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.tariff_map (
    source_tariff_id text PRIMARY KEY,
    target_tariff_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.subscription_map (
    source_subscription_id text PRIMARY KEY,
    target_subscription_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.payment_map (
    source_payment_id text PRIMARY KEY,
    target_transaction_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.ticket_map (
    source_ticket_id text PRIMARY KEY,
    target_ticket_id integer NOT NULL,
    target_user_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.ticket_message_map (
    source_ticket_message_id text PRIMARY KEY,
    target_ticket_message_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS migration_stealthnet.promocode_map (
    source_promocode_id text PRIMARY KEY,
    target_promocode_id integer NOT NULL,
    mapped_at timestamptz NOT NULL DEFAULT now()
);

\echo '[phase] load source tables from staging database'
CREATE TEMP TABLE src_clients AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        email,
        password_hash,
        role,
        remnawave_uuid,
        referral_code,
        referrer_id,
        balance,
        preferred_lang,
        preferred_currency,
        telegram_id,
        telegram_username,
        is_blocked,
        block_reason,
        referral_percent,
        trial_used,
        created_at,
        updated_at,
        apple_id,
        google_id,
        auto_renew_enabled
    FROM public.clients
    $$
) AS t(
    id text,
    email text,
    password_hash text,
    role text,
    remnawave_uuid text,
    referral_code text,
    referrer_id text,
    balance double precision,
    preferred_lang text,
    preferred_currency text,
    telegram_id text,
    telegram_username text,
    is_blocked boolean,
    block_reason text,
    referral_percent double precision,
    trial_used boolean,
    created_at timestamp,
    updated_at timestamp,
    apple_id text,
    google_id text,
    auto_renew_enabled boolean
);

CREATE TEMP TABLE src_tariffs AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        category_id,
        name,
        duration_days,
        internal_squad_uuids,
        traffic_limit_bytes,
        device_limit,
        price,
        currency,
        sort_order,
        created_at,
        updated_at,
        description,
        traffic_reset_mode
    FROM public.tariffs
    $$
) AS t(
    id text,
    category_id text,
    name text,
    duration_days integer,
    internal_squad_uuids text[],
    traffic_limit_bytes bigint,
    device_limit integer,
    price double precision,
    currency text,
    sort_order integer,
    created_at timestamp,
    updated_at timestamp,
    description text,
    traffic_reset_mode text
);

CREATE TEMP TABLE src_promo_groups AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        name,
        code,
        squad_uuid,
        traffic_limit_bytes,
        device_limit,
        duration_days,
        max_activations,
        is_active,
        created_at,
        updated_at
    FROM public.promo_groups
    $$
) AS t(
    id text,
    name text,
    code text,
    squad_uuid text,
    traffic_limit_bytes bigint,
    device_limit integer,
    duration_days integer,
    max_activations integer,
    is_active boolean,
    created_at timestamp,
    updated_at timestamp
);

CREATE TEMP TABLE src_secondary_subscriptions AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        owner_id,
        remnawave_uuid,
        subscription_index,
        tariff_id,
        gift_status,
        gifted_to_client_id,
        created_at,
        updated_at
    FROM public.secondary_subscriptions
    $$
) AS t(
    id text,
    owner_id text,
    remnawave_uuid text,
    subscription_index integer,
    tariff_id text,
    gift_status text,
    gifted_to_client_id text,
    created_at timestamp,
    updated_at timestamp
);

CREATE TEMP TABLE src_payments AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        client_id,
        order_id,
        amount,
        currency,
        status,
        provider,
        external_id,
        tariff_id,
        remnawave_user_id,
        metadata,
        created_at,
        paid_at,
        referral_distributed_at,
        proxy_tariff_id,
        singbox_tariff_id
    FROM public.payments
    $$
) AS t(
    id text,
    client_id text,
    order_id text,
    amount double precision,
    currency text,
    status text,
    provider text,
    external_id text,
    tariff_id text,
    remnawave_user_id text,
    metadata text,
    created_at timestamp,
    paid_at timestamp,
    referral_distributed_at timestamp,
    proxy_tariff_id text,
    singbox_tariff_id text
);

CREATE TEMP TABLE src_tickets AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        client_id,
        subject,
        status,
        created_at,
        updated_at
    FROM public.tickets
    $$
) AS t(
    id text,
    client_id text,
    subject text,
    status text,
    created_at timestamp,
    updated_at timestamp
);

CREATE TEMP TABLE src_ticket_messages AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        ticket_id,
        author_type,
        content,
        is_read,
        created_at
    FROM public.ticket_messages
    $$
) AS t(
    id text,
    ticket_id text,
    author_type text,
    content text,
    is_read boolean,
    created_at timestamp
);

CREATE TEMP TABLE src_system_settings AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT id, key, value
    FROM public.system_settings
    $$
) AS t(
    id text,
    key text,
    value text
);

CREATE TEMP TABLE src_promo_codes AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        id,
        code,
        name,
        type,
        discount_percent,
        discount_fixed,
        squad_uuid,
        traffic_limit_bytes,
        device_limit,
        duration_days,
        max_uses,
        max_uses_per_client,
        is_active,
        expires_at,
        created_at,
        updated_at
    FROM public.promo_codes
    $$
) AS t(
    id text,
    code text,
    name text,
    type text,
    discount_percent double precision,
    discount_fixed double precision,
    squad_uuid text,
    traffic_limit_bytes bigint,
    device_limit integer,
    duration_days integer,
    max_uses integer,
    max_uses_per_client integer,
    is_active boolean,
    expires_at timestamp,
    created_at timestamp,
    updated_at timestamp
);

CREATE TEMP TABLE src_promo_code_usages AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT id, promo_code_id, client_id, created_at
    FROM public.promo_code_usages
    $$
) AS t(
    id text,
    promo_code_id text,
    client_id text,
    created_at timestamp
);

CREATE TEMP TABLE src_promo_activations AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT id, promo_group_id, client_id, created_at
    FROM public.promo_activations
    $$
) AS t(
    id text,
    promo_group_id text,
    client_id text,
    created_at timestamp
);

CREATE TEMP TABLE src_table_meta AS
SELECT *
FROM dblink(
    'dbname=' || :'source_db',
    $$
    SELECT
        t.table_name,
        (
            SELECT kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
               AND tc.table_schema = kcu.table_schema
               AND tc.table_name = kcu.table_name
            WHERE tc.constraint_type = 'PRIMARY KEY'
              AND tc.table_schema = 'public'
              AND tc.table_name = t.table_name
            ORDER BY kcu.ordinal_position
            LIMIT 1
        ) AS pk_column
    FROM information_schema.tables t
    WHERE t.table_schema = 'public'
      AND t.table_type = 'BASE TABLE'
    ORDER BY t.table_name
    $$
) AS t(
    table_name text,
    pk_column text
);

\echo '[phase] archive all source rows into legacy_stealthnet.raw_rows'
SELECT set_config('migration_stealthnet.source_db', :'source_db', false);
DO $$
DECLARE
    rec record;
    src_db text := current_setting('migration_stealthnet.source_db', true);
    conn text := 'dbname=' || src_db;
    source_sql text;
    inserted_rows bigint;
BEGIN
    FOR rec IN SELECT table_name, pk_column FROM src_table_meta LOOP
        IF rec.pk_column IS NULL THEN
            source_sql := format(
                'SELECT NULL::text AS source_pk, to_jsonb(t) AS row_data FROM public.%I t',
                rec.table_name
            );
        ELSE
            source_sql := format(
                'SELECT t.%I::text AS source_pk, to_jsonb(t) AS row_data FROM public.%I t',
                rec.pk_column,
                rec.table_name
            );
        END IF;

        EXECUTE format(
            'INSERT INTO legacy_stealthnet.raw_rows(source_db, source_table, source_pk, row_data)
             SELECT %L, %L, d.source_pk, d.row_data
             FROM dblink(%L, %L) AS d(source_pk text, row_data jsonb)',
            src_db,
            rec.table_name,
            conn,
            source_sql
        );

        GET DIAGNOSTICS inserted_rows = ROW_COUNT;
        RAISE NOTICE 'archived table %, rows=%', rec.table_name, inserted_rows;
    END LOOP;
END $$;

\echo '[phase] ensure users defaults compatibility'
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'users'
          AND column_name = 'has_had_paid_subscription'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN has_had_paid_subscription SET DEFAULT false';
        EXECUTE 'UPDATE users SET has_had_paid_subscription = false WHERE has_had_paid_subscription IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'email_verified'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN email_verified SET DEFAULT false';
        EXECUTE 'UPDATE users SET email_verified = false WHERE email_verified IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'auto_promo_group_assigned'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN auto_promo_group_assigned SET DEFAULT false';
        EXECUTE 'UPDATE users SET auto_promo_group_assigned = false WHERE auto_promo_group_assigned IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'auto_promo_group_threshold_kopeks'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN auto_promo_group_threshold_kopeks SET DEFAULT 0';
        EXECUTE 'UPDATE users SET auto_promo_group_threshold_kopeks = 0 WHERE auto_promo_group_threshold_kopeks IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'promo_offer_discount_percent'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN promo_offer_discount_percent SET DEFAULT 0';
        EXECUTE 'UPDATE users SET promo_offer_discount_percent = 0 WHERE promo_offer_discount_percent IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'restriction_topup'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN restriction_topup SET DEFAULT false';
        EXECUTE 'UPDATE users SET restriction_topup = false WHERE restriction_topup IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'restriction_subscription'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN restriction_subscription SET DEFAULT false';
        EXECUTE 'UPDATE users SET restriction_subscription = false WHERE restriction_subscription IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'partner_status'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN partner_status SET DEFAULT ''none''';
        EXECUTE 'UPDATE users SET partner_status = ''none'' WHERE partner_status IS NULL';
    END IF;

    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'has_made_first_topup'
    ) THEN
        EXECUTE 'ALTER TABLE users ALTER COLUMN has_made_first_topup SET DEFAULT false';
        EXECUTE 'UPDATE users SET has_made_first_topup = false WHERE has_made_first_topup IS NULL';
    END IF;
END $$;

\echo '[phase] migrate clients -> users'
DO $$
DECLARE
    rec record;
    target_user_id integer;
    tg_id bigint;
    language_code text;
    inserted_count integer := 0;
    updated_count integer := 0;
    mapped_count integer := 0;
BEGIN
    FOR rec IN SELECT * FROM src_clients ORDER BY COALESCE(created_at, updated_at), id LOOP
        target_user_id := NULL;

        SELECT cm.target_user_id
          INTO target_user_id
          FROM migration_stealthnet.client_map cm
          JOIN users u ON u.id = cm.target_user_id
         WHERE cm.source_client_id = rec.id
         LIMIT 1;

        IF rec.telegram_id IS NOT NULL AND rec.telegram_id ~ '^[-]?[0-9]+$' THEN
            tg_id := rec.telegram_id::bigint;
        ELSE
            tg_id := NULL;
        END IF;

        IF target_user_id IS NULL AND tg_id IS NOT NULL THEN
            SELECT u.id INTO target_user_id FROM users u WHERE u.telegram_id = tg_id LIMIT 1;
        END IF;

        IF target_user_id IS NULL AND NULLIF(btrim(COALESCE(rec.email, '')), '') IS NOT NULL THEN
            SELECT u.id
              INTO target_user_id
              FROM users u
             WHERE lower(u.email) = lower(rec.email)
             LIMIT 1;
        END IF;

        IF COALESCE(rec.preferred_lang, '') ~ '^[A-Za-z_-]{2,5}$' THEN
            language_code := lower(left(rec.preferred_lang, 5));
        ELSE
            language_code := 'ru';
        END IF;

        IF target_user_id IS NULL THEN
            INSERT INTO users (
                telegram_id,
                auth_type,
                username,
                status,
                language,
                balance_kopeks,
                used_promocodes,
                has_had_paid_subscription,
                referral_code,
                created_at,
                updated_at,
                last_activity,
                remnawave_uuid,
                email,
                email_verified,
                password_hash,
                google_id,
                auto_promo_group_assigned,
                auto_promo_group_threshold_kopeks,
                promo_offer_discount_percent,
                restriction_topup,
                restriction_subscription,
                partner_status,
                has_made_first_topup
            )
            VALUES (
                tg_id,
                CASE WHEN tg_id IS NOT NULL THEN 'telegram' ELSE 'email' END,
                NULLIF(rec.telegram_username, ''),
                CASE WHEN COALESCE(rec.is_blocked, false) THEN 'blocked' ELSE 'active' END,
                language_code,
                GREATEST(0, round(COALESCE(rec.balance, 0) * 100.0)::integer),
                0,
                false,
                NULLIF(rec.referral_code, ''),
                COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                NULLIF(rec.remnawave_uuid, ''),
                NULLIF(lower(rec.email), ''),
                false,
                NULLIF(rec.password_hash, ''),
                NULLIF(rec.google_id, ''),
                false,
                0,
                0,
                false,
                false,
                'none',
                false
            )
            RETURNING id INTO target_user_id;
            inserted_count := inserted_count + 1;
        ELSE
            UPDATE users u
               SET username = COALESCE(u.username, NULLIF(rec.telegram_username, '')),
                   status = CASE
                       WHEN u.status = 'blocked' THEN u.status
                       WHEN COALESCE(rec.is_blocked, false) THEN 'blocked'
                       ELSE u.status
                   END,
                   language = COALESCE(NULLIF(u.language, ''), language_code),
                   referral_code = COALESCE(u.referral_code, NULLIF(rec.referral_code, '')),
                   remnawave_uuid = COALESCE(u.remnawave_uuid, NULLIF(rec.remnawave_uuid, '')),
                   email = COALESCE(u.email, NULLIF(lower(rec.email), '')),
                   password_hash = COALESCE(u.password_hash, NULLIF(rec.password_hash, '')),
                   google_id = COALESCE(u.google_id, NULLIF(rec.google_id, '')),
                   updated_at = GREATEST(
                       COALESCE(u.updated_at, '-infinity'::timestamptz),
                       COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
                   )
             WHERE u.id = target_user_id;
            updated_count := updated_count + 1;
        END IF;

        INSERT INTO migration_stealthnet.client_map(source_client_id, target_user_id)
        VALUES (rec.id, target_user_id)
        ON CONFLICT (source_client_id)
        DO UPDATE SET target_user_id = EXCLUDED.target_user_id,
                      mapped_at = now();

        mapped_count := mapped_count + 1;
    END LOOP;

    UPDATE users u
       SET referred_by_id = cm_ref.target_user_id,
           updated_at = GREATEST(
               COALESCE(u.updated_at, '-infinity'::timestamptz),
               COALESCE(sc.updated_at, sc.created_at, now()::timestamp) AT TIME ZONE 'UTC'
           )
      FROM src_clients sc
      JOIN migration_stealthnet.client_map cm_self ON cm_self.source_client_id = sc.id
      JOIN migration_stealthnet.client_map cm_ref ON cm_ref.source_client_id = sc.referrer_id
     WHERE u.id = cm_self.target_user_id
       AND cm_ref.target_user_id IS DISTINCT FROM u.id
       AND (u.referred_by_id IS NULL OR u.referred_by_id <> cm_ref.target_user_id);

    -- Ensure balances are synchronized for both inserted and pre-existing users,
    -- and resolve merged duplicates by taking the maximum source balance.
    UPDATE users u
       SET balance_kopeks = bal.max_balance_kopeks,
           updated_at = GREATEST(
               COALESCE(u.updated_at, '-infinity'::timestamptz),
               now()
           )
      FROM (
          SELECT
              cm.target_user_id,
              MAX(GREATEST(0, round(COALESCE(sc.balance, 0) * 100.0)::integer)) AS max_balance_kopeks
          FROM migration_stealthnet.client_map cm
          JOIN src_clients sc ON sc.id = cm.source_client_id
          GROUP BY cm.target_user_id
      ) bal
     WHERE u.id = bal.target_user_id
       AND u.balance_kopeks IS DISTINCT FROM bal.max_balance_kopeks;

    RAISE NOTICE 'clients migrated: inserted=%, updated=%, mapped=%', inserted_count, updated_count, mapped_count;
END $$;

\echo '[phase] migrate promo_groups'
DO $$
DECLARE
    rec record;
    target_promo_group_id integer;
    pg_name text;
BEGIN
    FOR rec IN SELECT * FROM src_promo_groups ORDER BY COALESCE(created_at, updated_at), id LOOP
        target_promo_group_id := NULL;

        SELECT pm.target_promo_group_id
          INTO target_promo_group_id
          FROM migration_stealthnet.promo_group_map pm
          JOIN promo_groups pg ON pg.id = pm.target_promo_group_id
         WHERE pm.source_promo_group_id = rec.id
         LIMIT 1;

        pg_name := NULLIF(btrim(COALESCE(rec.name, '')), '');
        IF pg_name IS NULL THEN
            pg_name := 'Legacy Promo ' || left(rec.id, 8);
        END IF;
        pg_name := left(pg_name, 255);

        IF target_promo_group_id IS NULL THEN
            SELECT id INTO target_promo_group_id FROM promo_groups WHERE lower(name) = lower(pg_name) LIMIT 1;
        END IF;

        IF target_promo_group_id IS NULL THEN
            INSERT INTO promo_groups(
                name,
                priority,
                server_discount_percent,
                traffic_discount_percent,
                device_discount_percent,
                period_discounts,
                apply_discounts_to_addons,
                is_default,
                created_at,
                updated_at
            )
            VALUES (
                pg_name,
                0,
                0,
                0,
                0,
                '{}'::jsonb,
                true,
                false,
                COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
            )
            RETURNING id INTO target_promo_group_id;
        END IF;

        INSERT INTO migration_stealthnet.promo_group_map(source_promo_group_id, target_promo_group_id)
        VALUES (rec.id, target_promo_group_id)
        ON CONFLICT (source_promo_group_id)
        DO UPDATE SET target_promo_group_id = EXCLUDED.target_promo_group_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'promo groups mapped: %', (SELECT count(*) FROM migration_stealthnet.promo_group_map);
END $$;

\echo '[phase] migrate tariffs'
DO $$
DECLARE
    rec record;
    target_tariff_id integer;
    tariff_name text;
    period_days integer;
    period_price_kopeks integer;
    traffic_limit_gb integer;
    squads_json jsonb;
BEGIN
    FOR rec IN SELECT * FROM src_tariffs ORDER BY COALESCE(created_at, updated_at), id LOOP
        target_tariff_id := NULL;

        SELECT tm.target_tariff_id
          INTO target_tariff_id
          FROM migration_stealthnet.tariff_map tm
          JOIN tariffs t ON t.id = tm.target_tariff_id
         WHERE tm.source_tariff_id = rec.id
         LIMIT 1;

        tariff_name := NULLIF(btrim(COALESCE(rec.name, '')), '');
        IF tariff_name IS NULL THEN
            tariff_name := 'Legacy Tariff ' || left(rec.id, 8);
        END IF;
        tariff_name := left(tariff_name, 255);

        period_days := GREATEST(1, COALESCE(rec.duration_days, 30));
        period_price_kopeks := GREATEST(0, round(COALESCE(rec.price, 0) * 100.0)::integer);

        traffic_limit_gb := CASE
            WHEN rec.traffic_limit_bytes IS NULL OR rec.traffic_limit_bytes <= 0 THEN 0
            ELSE CEIL(rec.traffic_limit_bytes / 1073741824.0)::integer
        END;

        squads_json := COALESCE(to_jsonb(rec.internal_squad_uuids), '[]'::jsonb);

        IF target_tariff_id IS NULL THEN
            SELECT id
              INTO target_tariff_id
              FROM tariffs
             WHERE lower(name) = lower(tariff_name)
               AND display_order = COALESCE(rec.sort_order, 0)
             LIMIT 1;
        END IF;

        IF target_tariff_id IS NULL THEN
            INSERT INTO tariffs (
                name,
                description,
                display_order,
                is_active,
                traffic_limit_gb,
                device_limit,
                allowed_squads,
                period_prices,
                tier_level,
                is_trial_available,
                allow_traffic_topup,
                traffic_topup_enabled,
                traffic_topup_packages,
                max_topup_traffic_gb,
                is_daily,
                daily_price_kopeks,
                custom_days_enabled,
                price_per_day_kopeks,
                min_days,
                max_days,
                custom_traffic_enabled,
                traffic_price_per_gb_kopeks,
                min_traffic_gb,
                max_traffic_gb,
                show_in_gift,
                traffic_reset_mode,
                external_squad_uuid,
                created_at,
                updated_at
            )
            VALUES (
                tariff_name,
                NULLIF(rec.description, ''),
                COALESCE(rec.sort_order, 0),
                true,
                traffic_limit_gb,
                GREATEST(1, COALESCE(rec.device_limit, 1)),
                squads_json::json,
                jsonb_build_object(period_days::text, period_price_kopeks)::json,
                1,
                false,
                true,
                false,
                '{}'::json,
                0,
                false,
                0,
                false,
                0,
                1,
                365,
                false,
                0,
                1,
                1000,
                true,
                NULL,
                COALESCE(rec.internal_squad_uuids[1], NULL),
                COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
            )
            RETURNING id INTO target_tariff_id;
        END IF;

        INSERT INTO migration_stealthnet.tariff_map(source_tariff_id, target_tariff_id)
        VALUES (rec.id, target_tariff_id)
        ON CONFLICT (source_tariff_id)
        DO UPDATE SET target_tariff_id = EXCLUDED.target_tariff_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'tariffs mapped: %', (SELECT count(*) FROM migration_stealthnet.tariff_map);
END $$;

\echo '[phase] migrate secondary_subscriptions -> subscriptions'
SELECT set_config('migration_stealthnet.subs_mode', :'subs_mode', false);
DO $$
DECLARE
    rec record;
    target_subscription_id integer;
    target_user_id integer;
    target_tariff_id integer;
    duration_days integer;
    start_ts timestamptz;
    end_ts timestamptz;
    status_value text;
    subs_mode text := COALESCE(NULLIF(current_setting('migration_stealthnet.subs_mode', true), ''), 'expired');
    tariff_traffic_limit integer;
    tariff_device_limit integer;
    tariff_squads jsonb;
BEGIN
    FOR rec IN SELECT * FROM src_secondary_subscriptions ORDER BY COALESCE(created_at, updated_at), id LOOP
        SELECT cm.target_user_id INTO target_user_id
          FROM migration_stealthnet.client_map cm
         WHERE cm.source_client_id = rec.owner_id
         LIMIT 1;

        IF target_user_id IS NULL THEN
            CONTINUE;
        END IF;

        SELECT tm.target_tariff_id INTO target_tariff_id
          FROM migration_stealthnet.tariff_map tm
         WHERE tm.source_tariff_id = rec.tariff_id
         LIMIT 1;

        SELECT sm.target_subscription_id
          INTO target_subscription_id
          FROM migration_stealthnet.subscription_map sm
          JOIN subscriptions s ON s.id = sm.target_subscription_id
         WHERE sm.source_subscription_id = rec.id
         LIMIT 1;

        IF target_subscription_id IS NULL AND NULLIF(rec.remnawave_uuid, '') IS NOT NULL THEN
            SELECT s.id INTO target_subscription_id
              FROM subscriptions s
             WHERE s.remnawave_uuid = rec.remnawave_uuid
             ORDER BY s.id
             LIMIT 1;
        END IF;

        IF target_subscription_id IS NOT NULL THEN
            INSERT INTO migration_stealthnet.subscription_map(source_subscription_id, target_subscription_id)
            VALUES (rec.id, target_subscription_id)
            ON CONFLICT (source_subscription_id)
            DO UPDATE SET target_subscription_id = EXCLUDED.target_subscription_id,
                          mapped_at = now();
            CONTINUE;
        END IF;

        IF target_tariff_id IS NOT NULL THEN
            SELECT
                COALESCE(MIN((kv.key)::integer), 30)
            INTO duration_days
            FROM tariffs t
            LEFT JOIN LATERAL jsonb_each(t.period_prices::jsonb) kv ON true
            WHERE t.id = target_tariff_id
              AND kv.key ~ '^[0-9]+$';

            SELECT t.traffic_limit_gb, t.device_limit, COALESCE(t.allowed_squads::jsonb, '[]'::jsonb)
              INTO tariff_traffic_limit, tariff_device_limit, tariff_squads
              FROM tariffs t
             WHERE t.id = target_tariff_id;
        ELSE
            duration_days := 30;
            tariff_traffic_limit := 0;
            tariff_device_limit := 1;
            tariff_squads := '[]'::jsonb;
        END IF;

        start_ts := COALESCE(rec.created_at, rec.updated_at, now()::timestamp) AT TIME ZONE 'UTC';

        IF subs_mode = 'active' THEN
            status_value := CASE WHEN NULLIF(rec.remnawave_uuid, '') IS NOT NULL THEN 'active' ELSE 'pending' END;
            end_ts := start_ts + make_interval(days => GREATEST(1, COALESCE(duration_days, 30)));
        ELSE
            status_value := 'expired';
            end_ts := COALESCE(rec.updated_at, rec.created_at, (now() - interval '1 day')::timestamp) AT TIME ZONE 'UTC';
            IF end_ts > now() THEN
                end_ts := now() - interval '1 second';
            END IF;
        END IF;

        IF end_ts <= start_ts THEN
            IF status_value = 'expired' THEN
                end_ts := start_ts;
            ELSE
                end_ts := start_ts + interval '1 day';
            END IF;
        END IF;

        BEGIN
            INSERT INTO subscriptions (
                user_id,
                status,
                is_trial,
                start_date,
                end_date,
                traffic_limit_gb,
                traffic_used_gb,
                purchased_traffic_gb,
                device_limit,
                connected_squads,
                autopay_enabled,
                autopay_days_before,
                created_at,
                updated_at,
                remnawave_short_uuid,
                remnawave_uuid,
                remnawave_short_id,
                tariff_id,
                is_daily_paused
            )
            VALUES (
                target_user_id,
                status_value,
                false,
                start_ts,
                end_ts,
                COALESCE(tariff_traffic_limit, 0),
                0.0,
                0,
                GREATEST(1, COALESCE(tariff_device_limit, 1)),
                COALESCE(tariff_squads, '[]'::jsonb)::json,
                false,
                3,
                start_ts,
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                CASE WHEN NULLIF(rec.remnawave_uuid, '') IS NOT NULL THEN left(replace(rec.remnawave_uuid, '-', ''), 8) ELSE NULL END,
                NULLIF(rec.remnawave_uuid, ''),
                left(md5('stealthnet-sub:' || COALESCE(rec.id, '')), 16),
                target_tariff_id,
                false
            )
            RETURNING id INTO target_subscription_id;
        EXCEPTION
            WHEN unique_violation THEN
                INSERT INTO subscriptions (
                    user_id,
                    status,
                    is_trial,
                    start_date,
                    end_date,
                    traffic_limit_gb,
                    traffic_used_gb,
                    purchased_traffic_gb,
                    device_limit,
                    connected_squads,
                    autopay_enabled,
                    autopay_days_before,
                    created_at,
                    updated_at,
                    remnawave_short_uuid,
                    remnawave_uuid,
                    remnawave_short_id,
                    tariff_id,
                    is_daily_paused
                )
                VALUES (
                    target_user_id,
                    'expired',
                    false,
                    start_ts,
                    LEAST(end_ts, now() - interval '1 second'),
                    COALESCE(tariff_traffic_limit, 0),
                    0.0,
                    0,
                    GREATEST(1, COALESCE(tariff_device_limit, 1)),
                    COALESCE(tariff_squads, '[]'::jsonb)::json,
                    false,
                    3,
                    start_ts,
                    COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                    CASE WHEN NULLIF(rec.remnawave_uuid, '') IS NOT NULL THEN left(replace(rec.remnawave_uuid, '-', ''), 8) ELSE NULL END,
                    NULLIF(rec.remnawave_uuid, ''),
                    left(md5('stealthnet-sub:' || COALESCE(rec.id, '')), 16),
                    target_tariff_id,
                    false
                )
                RETURNING id INTO target_subscription_id;
        END;

        INSERT INTO migration_stealthnet.subscription_map(source_subscription_id, target_subscription_id)
        VALUES (rec.id, target_subscription_id)
        ON CONFLICT (source_subscription_id)
        DO UPDATE SET target_subscription_id = EXCLUDED.target_subscription_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'subscriptions mapped: %', (SELECT count(*) FROM migration_stealthnet.subscription_map);
END $$;

\echo '[phase] migrate payments -> transactions'
DO $$
DECLARE
    rec record;
    target_user_id integer;
    target_transaction_id integer;
    payment_method_value text;
    external_key text;
    status_norm text;
    is_completed_value boolean;
    type_value text;
    completed_ts timestamptz;
BEGIN
    FOR rec IN SELECT * FROM src_payments ORDER BY COALESCE(created_at, paid_at), id LOOP
        SELECT pm.target_transaction_id
          INTO target_transaction_id
          FROM migration_stealthnet.payment_map pm
          JOIN transactions tx ON tx.id = pm.target_transaction_id
         WHERE pm.source_payment_id = rec.id
         LIMIT 1;

        IF target_transaction_id IS NOT NULL THEN
            CONTINUE;
        END IF;

        SELECT cm.target_user_id INTO target_user_id
          FROM migration_stealthnet.client_map cm
         WHERE cm.source_client_id = rec.client_id
         LIMIT 1;

        IF target_user_id IS NULL THEN
            CONTINUE;
        END IF;

        status_norm := lower(COALESCE(rec.status, ''));
        is_completed_value := status_norm IN ('paid', 'success', 'succeeded', 'completed', 'done');

        IF is_completed_value AND (NULLIF(rec.tariff_id, '') IS NOT NULL OR NULLIF(rec.proxy_tariff_id, '') IS NOT NULL OR NULLIF(rec.singbox_tariff_id, '') IS NOT NULL) THEN
            type_value := 'subscription_payment';
        ELSIF is_completed_value THEN
            type_value := 'deposit';
        ELSE
            type_value := 'deposit';
        END IF;

        payment_method_value := COALESCE(NULLIF(lower(rec.provider), ''), 'legacy_stealthnet');
        external_key := COALESCE(NULLIF(rec.external_id, ''), NULLIF(rec.order_id, ''), rec.id);

        IF is_completed_value THEN
            completed_ts := COALESCE(rec.paid_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC';
        ELSE
            completed_ts := NULL;
        END IF;

        INSERT INTO transactions (
            user_id,
            type,
            amount_kopeks,
            description,
            payment_method,
            external_id,
            is_completed,
            created_at,
            completed_at
        )
        VALUES (
            target_user_id,
            type_value,
            GREATEST(0, round(COALESCE(rec.amount, 0) * 100.0)::integer),
            left(
                format(
                    'StealthNet payment id=%s order=%s provider=%s status=%s',
                    COALESCE(rec.id, ''),
                    COALESCE(rec.order_id, ''),
                    COALESCE(rec.provider, ''),
                    COALESCE(rec.status, '')
                ),
                2000
            ),
            payment_method_value,
            external_key,
            is_completed_value,
            COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
            completed_ts
        )
        ON CONFLICT (external_id, payment_method)
        DO UPDATE SET
            user_id = EXCLUDED.user_id,
            amount_kopeks = EXCLUDED.amount_kopeks,
            is_completed = EXCLUDED.is_completed,
            completed_at = COALESCE(transactions.completed_at, EXCLUDED.completed_at)
        RETURNING id INTO target_transaction_id;

        INSERT INTO migration_stealthnet.payment_map(source_payment_id, target_transaction_id)
        VALUES (rec.id, target_transaction_id)
        ON CONFLICT (source_payment_id)
        DO UPDATE SET target_transaction_id = EXCLUDED.target_transaction_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'payments mapped: %', (SELECT count(*) FROM migration_stealthnet.payment_map);
END $$;

\echo '[phase] migrate tickets and ticket messages'
DO $$
DECLARE
    rec record;
    target_user_id integer;
    target_ticket_id integer;
    status_value text;
BEGIN
    FOR rec IN SELECT * FROM src_tickets ORDER BY COALESCE(created_at, updated_at), id LOOP
        SELECT tm.target_ticket_id
          INTO target_ticket_id
          FROM migration_stealthnet.ticket_map tm
          JOIN tickets t ON t.id = tm.target_ticket_id
         WHERE tm.source_ticket_id = rec.id
         LIMIT 1;

        IF target_ticket_id IS NOT NULL THEN
            CONTINUE;
        END IF;

        SELECT cm.target_user_id INTO target_user_id
          FROM migration_stealthnet.client_map cm
         WHERE cm.source_client_id = rec.client_id
         LIMIT 1;

        IF target_user_id IS NULL THEN
            CONTINUE;
        END IF;

        status_value := lower(COALESCE(rec.status, 'open'));
        IF status_value NOT IN ('open', 'answered', 'closed', 'pending') THEN
            status_value := 'open';
        END IF;

        INSERT INTO tickets (
            user_id,
            title,
            status,
            priority,
            user_reply_block_permanent,
            created_at,
            updated_at
        )
        VALUES (
            target_user_id,
            left(COALESCE(NULLIF(rec.subject, ''), 'Imported ticket'), 255),
            status_value,
            'normal',
            false,
            COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
            COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
        )
        RETURNING id INTO target_ticket_id;

        INSERT INTO migration_stealthnet.ticket_map(source_ticket_id, target_ticket_id, target_user_id)
        VALUES (rec.id, target_ticket_id, target_user_id)
        ON CONFLICT (source_ticket_id)
        DO UPDATE SET
            target_ticket_id = EXCLUDED.target_ticket_id,
            target_user_id = EXCLUDED.target_user_id,
            mapped_at = now();
    END LOOP;
END $$;

DO $$
DECLARE
    rec record;
    target_ticket_id integer;
    ticket_owner_user_id integer;
    target_ticket_message_id integer;
    is_from_admin_value boolean;
BEGIN
    FOR rec IN SELECT * FROM src_ticket_messages ORDER BY created_at, id LOOP
        SELECT tmm.target_ticket_message_id
          INTO target_ticket_message_id
          FROM migration_stealthnet.ticket_message_map tmm
          JOIN ticket_messages tm ON tm.id = tmm.target_ticket_message_id
         WHERE tmm.source_ticket_message_id = rec.id
         LIMIT 1;

        IF target_ticket_message_id IS NOT NULL THEN
            CONTINUE;
        END IF;

        SELECT tm.target_ticket_id, tm.target_user_id
          INTO target_ticket_id, ticket_owner_user_id
          FROM migration_stealthnet.ticket_map tm
         WHERE tm.source_ticket_id = rec.ticket_id
         LIMIT 1;

        IF target_ticket_id IS NULL OR ticket_owner_user_id IS NULL THEN
            CONTINUE;
        END IF;

        is_from_admin_value := lower(COALESCE(rec.author_type, '')) IN ('admin', 'support', 'operator', 'moderator');

        INSERT INTO ticket_messages (
            ticket_id,
            user_id,
            message_text,
            is_from_admin,
            has_media,
            created_at
        )
        VALUES (
            target_ticket_id,
            ticket_owner_user_id,
            COALESCE(NULLIF(rec.content, ''), '[empty imported message]'),
            is_from_admin_value,
            false,
            COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
        )
        RETURNING id INTO target_ticket_message_id;

        INSERT INTO migration_stealthnet.ticket_message_map(source_ticket_message_id, target_ticket_message_id)
        VALUES (rec.id, target_ticket_message_id)
        ON CONFLICT (source_ticket_message_id)
        DO UPDATE SET target_ticket_message_id = EXCLUDED.target_ticket_message_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'tickets mapped: %, ticket_messages mapped: %',
        (SELECT count(*) FROM migration_stealthnet.ticket_map),
        (SELECT count(*) FROM migration_stealthnet.ticket_message_map);
END $$;

\echo '[phase] migrate promo codes and uses'
CREATE TEMP TABLE src_promo_usage_counts AS
SELECT promo_code_id, count(*)::integer AS usage_count
FROM src_promo_code_usages
GROUP BY promo_code_id;

DO $$
DECLARE
    rec record;
    target_promocode_id integer;
    target_tariff_id integer;
    ptype text;
    balance_bonus integer;
    sub_days integer;
    usage_count integer;
    max_uses_value integer;
BEGIN
    FOR rec IN SELECT * FROM src_promo_codes ORDER BY COALESCE(created_at, updated_at), id LOOP
        SELECT pm.target_promocode_id
          INTO target_promocode_id
          FROM migration_stealthnet.promocode_map pm
          JOIN promocodes p ON p.id = pm.target_promocode_id
         WHERE pm.source_promocode_id = rec.id
         LIMIT 1;

        -- StealthNet promo_codes schema has no direct tariff FK.
        -- Keep NULL here and preserve full raw record in legacy_stealthnet.raw_rows.
        target_tariff_id := NULL;

        SELECT COALESCE(puc.usage_count, 0)
          INTO usage_count
          FROM src_promo_usage_counts puc
         WHERE puc.promo_code_id = rec.id;

        IF COALESCE(rec.duration_days, 0) > 0 THEN
            ptype := 'subscription_days';
            sub_days := GREATEST(0, rec.duration_days);
            balance_bonus := 0;
        ELSIF COALESCE(rec.discount_fixed, 0) > 0 THEN
            ptype := 'balance';
            sub_days := 0;
            balance_bonus := GREATEST(0, round(rec.discount_fixed * 100.0)::integer);
        ELSE
            ptype := 'balance';
            sub_days := 0;
            balance_bonus := 0;
        END IF;

        max_uses_value := COALESCE(rec.max_uses, 0);
        IF max_uses_value <= 0 THEN
            max_uses_value := 999999;
        END IF;

        IF target_promocode_id IS NULL THEN
            SELECT p.id INTO target_promocode_id FROM promocodes p WHERE p.code = rec.code LIMIT 1;
        END IF;

        IF target_promocode_id IS NULL THEN
            INSERT INTO promocodes (
                code,
                type,
                balance_bonus_kopeks,
                subscription_days,
                max_uses,
                current_uses,
                valid_from,
                valid_until,
                is_active,
                first_purchase_only,
                tariff_id,
                created_by,
                promo_group_id,
                created_at,
                updated_at
            )
            VALUES (
                left(COALESCE(rec.code, 'LEGACY_' || rec.id), 50),
                ptype,
                balance_bonus,
                sub_days,
                max_uses_value,
                LEAST(max_uses_value, GREATEST(0, usage_count)),
                COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                CASE WHEN rec.expires_at IS NULL THEN NULL ELSE rec.expires_at AT TIME ZONE 'UTC' END,
                COALESCE(rec.is_active, true),
                false,
                target_tariff_id,
                NULL,
                NULL,
                COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
                COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
            )
            RETURNING id INTO target_promocode_id;
        ELSE
            UPDATE promocodes p
               SET type = COALESCE(p.type, ptype),
                   current_uses = GREATEST(p.current_uses, LEAST(max_uses_value, GREATEST(0, usage_count))),
                   is_active = p.is_active OR COALESCE(rec.is_active, false),
                   valid_until = COALESCE(p.valid_until, CASE WHEN rec.expires_at IS NULL THEN NULL ELSE rec.expires_at AT TIME ZONE 'UTC' END),
                   updated_at = GREATEST(
                       COALESCE(p.updated_at, '-infinity'::timestamptz),
                       COALESCE(rec.updated_at, rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
                   )
             WHERE p.id = target_promocode_id;
        END IF;

        INSERT INTO migration_stealthnet.promocode_map(source_promocode_id, target_promocode_id)
        VALUES (rec.id, target_promocode_id)
        ON CONFLICT (source_promocode_id)
        DO UPDATE SET target_promocode_id = EXCLUDED.target_promocode_id,
                      mapped_at = now();
    END LOOP;

    RAISE NOTICE 'promocodes mapped: %', (SELECT count(*) FROM migration_stealthnet.promocode_map);
END $$;

DO $$
DECLARE
    rec record;
    target_promocode_id integer;
    target_user_id integer;
BEGIN
    FOR rec IN SELECT * FROM src_promo_code_usages ORDER BY created_at, id LOOP
        SELECT pm.target_promocode_id INTO target_promocode_id
          FROM migration_stealthnet.promocode_map pm
         WHERE pm.source_promocode_id = rec.promo_code_id
         LIMIT 1;

        SELECT cm.target_user_id INTO target_user_id
          FROM migration_stealthnet.client_map cm
         WHERE cm.source_client_id = rec.client_id
         LIMIT 1;

        IF target_promocode_id IS NULL OR target_user_id IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO promocode_uses(promocode_id, user_id, used_at)
        VALUES (
            target_promocode_id,
            target_user_id,
            COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC'
        )
        ON CONFLICT (user_id, promocode_id)
        DO NOTHING;
    END LOOP;
END $$;

\echo '[phase] migrate promo activations -> user_promo_groups'
DO $$
DECLARE
    rec record;
    target_user_id integer;
    target_promo_group_id integer;
BEGIN
    FOR rec IN SELECT * FROM src_promo_activations ORDER BY created_at, id LOOP
        SELECT cm.target_user_id INTO target_user_id
          FROM migration_stealthnet.client_map cm
         WHERE cm.source_client_id = rec.client_id
         LIMIT 1;

        SELECT pm.target_promo_group_id INTO target_promo_group_id
          FROM migration_stealthnet.promo_group_map pm
         WHERE pm.source_promo_group_id = rec.promo_group_id
         LIMIT 1;

        IF target_user_id IS NULL OR target_promo_group_id IS NULL THEN
            CONTINUE;
        END IF;

        INSERT INTO user_promo_groups(user_id, promo_group_id, assigned_at, assigned_by)
        VALUES (
            target_user_id,
            target_promo_group_id,
            COALESCE(rec.created_at, now()::timestamp) AT TIME ZONE 'UTC',
            'stealthnet_migration'
        )
        ON CONFLICT (user_id, promo_group_id)
        DO NOTHING;

        UPDATE users
           SET promo_group_id = COALESCE(promo_group_id, target_promo_group_id)
         WHERE id = target_user_id;
    END LOOP;
END $$;

\echo '[phase] migrate system settings with legacy prefix'
DO $$
DECLARE
    rec record;
    prefixed_key text;
BEGIN
    FOR rec IN SELECT * FROM src_system_settings LOOP
        prefixed_key := left('legacy_stealthnet__' || COALESCE(rec.key, 'unknown_key'), 255);

        INSERT INTO system_settings(key, value, description, created_at, updated_at)
        VALUES (
            prefixed_key,
            rec.value,
            'Imported from StealthNet setting: ' || COALESCE(rec.key, ''),
            now(),
            now()
        )
        ON CONFLICT (key)
        DO UPDATE SET
            value = EXCLUDED.value,
            description = EXCLUDED.description,
            updated_at = now();
    END LOOP;
END $$;

\echo '[summary] migration counters'
SELECT 'src_clients' AS metric, count(*)::bigint AS value FROM src_clients
UNION ALL
SELECT 'src_tariffs', count(*)::bigint FROM src_tariffs
UNION ALL
SELECT 'src_secondary_subscriptions', count(*)::bigint FROM src_secondary_subscriptions
UNION ALL
SELECT 'src_payments', count(*)::bigint FROM src_payments
UNION ALL
SELECT 'src_tickets', count(*)::bigint FROM src_tickets
UNION ALL
SELECT 'src_ticket_messages', count(*)::bigint FROM src_ticket_messages
UNION ALL
SELECT 'src_promocodes', count(*)::bigint FROM src_promo_codes
UNION ALL
SELECT 'mapped_clients', count(*)::bigint FROM migration_stealthnet.client_map
UNION ALL
SELECT 'mapped_tariffs', count(*)::bigint FROM migration_stealthnet.tariff_map
UNION ALL
SELECT 'mapped_subscriptions', count(*)::bigint FROM migration_stealthnet.subscription_map
UNION ALL
SELECT 'mapped_payments', count(*)::bigint FROM migration_stealthnet.payment_map
UNION ALL
SELECT 'mapped_tickets', count(*)::bigint FROM migration_stealthnet.ticket_map
UNION ALL
SELECT 'mapped_ticket_messages', count(*)::bigint FROM migration_stealthnet.ticket_message_map
UNION ALL
SELECT 'mapped_promocodes', count(*)::bigint FROM migration_stealthnet.promocode_map
UNION ALL
SELECT 'legacy_raw_rows_total', count(*)::bigint FROM legacy_stealthnet.raw_rows;

\echo '[done] stealthnet_to_bedolaga.sql completed'
