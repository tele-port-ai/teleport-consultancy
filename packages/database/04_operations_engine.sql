-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 4 — OPERATIONS ENGINE (HARD BUSINESS RULES)
-- Depends on:
-- 00_identity_schema.sql
-- 01_case_engine.sql
-- 02_workflow_engine.sql
-- 03_document_system.sql
-- =========================================================

-- =========================================================
-- TASKS (IMMUTABLE COMPLETION)
-- =========================================================
create table if not exists tasks (
    id uuid primary key default uuid_generate_v4(),

    case_id uuid not null references cases(id) on delete cascade,

    title text not null,
    description text,

    is_blocking boolean not null default true,

    status text not null default 'pending'
        check (status in ('pending','in_progress','completed','cancelled')),

    assigned_to uuid references users(id),

    completed_by uuid references users(id),
    completed_at timestamptz,

    due_at timestamptz,

    created_at timestamptz not null default now()
);

create index idx_tasks_case on tasks(case_id);
create index idx_tasks_blocking on tasks(case_id, status) where is_blocking = true;

-- Prevent editing completed tasks
create or replace function prevent_task_edit_after_completion()
returns trigger as $$
begin
    if old.status = 'completed' then
        raise exception 'Completed tasks are immutable';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_lock_completed_tasks
before update on tasks
for each row execute procedure prevent_task_edit_after_completion();

-- Enforce completion fields
create or replace function enforce_task_completion()
returns trigger as $$
begin
    if new.status = 'completed' then
        if new.completed_by is null then
            raise exception 'completed_by required when completing task';
        end if;

        if new.completed_at is null then
            new.completed_at := now();
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_task_completion_fields
before update on tasks
for each row execute procedure enforce_task_completion();



-- =========================================================
-- APPOINTMENTS (MISSED EVENT DETECTION)
-- =========================================================
create table if not exists appointments (
    id uuid primary key default uuid_generate_v4(),

    case_id uuid not null references cases(id) on delete cascade,

    type text not null
        check (type in ('consultation','biometrics','embassy','medical')),

    scheduled_at timestamptz not null,

    attended boolean,
    marked_by uuid references users(id),

    created_at timestamptz not null default now()
);

create index idx_appointments_case on appointments(case_id);

-- Only one future biometrics allowed
create unique index uniq_future_biometrics
on appointments(case_id)
where type = 'biometrics'
and attended is null;



-- =========================================================
-- PAYMENTS (2-STEP ACCOUNTING CONFIRMATION)
-- =========================================================
create table if not exists payments (
    id uuid primary key default uuid_generate_v4(),

    case_id uuid not null references cases(id) on delete cascade,

    amount numeric(10,2) not null check (amount > 0),
    currency text not null default 'USD',

    recorded_by uuid not null references users(id),
    recorded_at timestamptz not null default now(),

    confirmed_by uuid references users(id),
    confirmed_at timestamptz,

    status text not null default 'pending'
        check (status in ('pending','confirmed','rejected')),

    note text
);

create index idx_payments_case on payments(case_id);
create index idx_payments_confirmed on payments(case_id, status);

-- Enforce finance confirmation
create or replace function enforce_payment_confirmation()
returns trigger as $$
begin
    if new.status = 'confirmed' then
        if new.confirmed_by is null then
            raise exception 'Finance must confirm payment';
        end if;

        if new.confirmed_at is null then
            new.confirmed_at := now();
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_payment_confirmation
before update on payments
for each row execute procedure enforce_payment_confirmation();



-- =========================================================
-- READINESS (COMPUTED — NEVER STORED)
-- =========================================================

create or replace view case_readiness as
select
    c.id as case_id,

    -- all blocking tasks finished
    not exists (
        select 1 from tasks t
        where t.case_id = c.id
        and t.is_blocking = true
        and t.status <> 'completed'
    ) as tasks_ready,

    -- confirmed payments exist
    exists (
        select 1 from payments p
        where p.case_id = c.id
        and p.status = 'confirmed'
    ) as payment_ready,

    -- no missed appointments
    not exists (
        select 1 from appointments a
        where a.case_id = c.id
        and a.attended is null
        and a.scheduled_at < now()
    ) as appointment_ready

from cases c;



-- Final readiness rule
create or replace view case_ready_for_submission as
select
    case_id,
    (tasks_ready and payment_ready and appointment_ready) as ready
from case_readiness;



-- =========================================================
-- END PHASE 4
-- =========================================================