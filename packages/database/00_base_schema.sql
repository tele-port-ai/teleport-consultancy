-- =========================================================
-- TELE PORT CONSULTANCY
-- PHASE 0 — PERMANENT IDENTITY CORE
-- Immutable Human Identity Layer
-- =========================================================

-- Required extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- =========================================================
-- ROLES (SYSTEM ACCESS ONLY — NOT BUSINESS LOGIC)
-- =========================================================
create table if not exists roles {
    id uuid primary key default uuid_generate_v4(),
    name text unique not null,
    description text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
};

insert into roles (name, description) values
('client', 'Portal user'),
('consultant', 'Staff consultant'),
('admin', 'System administrator')
on conflict (name) do nothing;

-- =========================================================
-- USERS (AUTH LINKED TO SUPABASE AUTH.USERS)
-- One record per login account
-- =========================================================
create table if not exists users {
    id uuid primary key, -- = auth.users.id
    role_id uuid not null references roles(id),

    email text not null unique,
    phone text,

    email_verified boolean not null default false,
    phone_verified boolean not null default false,
    is_active boolean not null default true,

    preferred_language text not null default 'en',
    timezone text not null default 'Africa/Addis_Ababa',

    last_login timestamptz,
    metadata jsonb not null default '{}'::jsonb,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz
};

create index idx_users_role on users(role_id);
create index idx_users_deleted on users(deleted_at) where deleted_at is null;

-- =========================================================
-- IDENTITY PROFILES
-- One real human = one identity profile
-- Reused across all future immigration cases
-- =========================================================
create table if not exists identity_profiles {
    id uuid primary key default uuid_generate_v4(),
    user_id uuid unique not null references users(id) on delete cascade,

    -- Legal identity
    first_name text not null,
    last_name text not null,
    date_of_birth date not null check (date_of_birth < current_date),
    gender text check (gender in ('male','female','other','prefer_not_to_say')),
    marital_status text check (marital_status in ('single','married','divorced','widowed','other')),

    -- Nationality
    nationality text,
    country_of_birth text,
    current_residence_country text,

    -- Passport (current valid passport only)
    passport_number text unique,
    passport_issue_date date,
    passport_expiry_date date check (passport_expiry_date > passport_issue_date),

    -- Immigration history baseline
    previous_refusal boolean not null default false,
    refusal_notes text,

    -- Education & skill baseline (used for eligibility pre-check)
    highest_education text check (highest_education in ('high_school','bachelor','master','phd','other')),
    field_of_study text,
    years_of_experience integer check (years_of_experience >= 0),
    english_level text check (english_level in ('beginner','intermediate','advanced','fluent','native')),

    -- Primary contact snapshot (not auth data)
    primary_phone text,
    primary_email text,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz
};

create index idx_identity_user on identity_profiles(user_id) where deleted_at is null;
create index idx_identity_passport on identity_profiles(passport_number) where deleted_at is null;

-- =========================================================
-- DEPENDENTS / FAMILY MEMBERS
-- Permanent people related to main applicant
-- NOT tied to any case yet
-- =========================================================
create table if not exists dependents {
    id uuid primary key default uuid_generate_v4(),
    owner_identity_id uuid not null references identity_profiles(id) on delete cascade,

    relationship text not null check (relationship in ('spouse','child','parent','dependent','other')),

    first_name text not null,
    last_name text not null,
    date_of_birth date check (date_of_birth < current_date),

    nationality text,
    passport_number text,
    passport_expiry_date date,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    deleted_at timestamptz
};

create index idx_dependents_owner on dependents(owner_identity_id) where deleted_at is null;

-- =========================================================
-- UPDATED_AT TRIGGER (GLOBAL)
-- =========================================================
create or replace function set_updated_at()
returns trigger as $$
begin
    new.updated_at = now();
    return new;
end;
$$ language plpgsql;

create trigger trg_users_updated before update on users for each row execute procedure set_updated_at();
create trigger trg_identity_updated before update on identity_profiles for each row execute procedure set_updated_at();
create trigger trg_dependents_updated before update on dependents for each row execute procedure set_updated_at();
create trigger trg_roles_updated before update on roles for each row execute procedure set_updated_at();

-- =========================================================
-- END PHASE 0
-- This schema should never require migration in production
-- =========================================================