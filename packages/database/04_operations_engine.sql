-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 4 — OPERATIONS ENGINE (PRODUCTION SAFE)
-- =========================================================

-- =========================================================
-- TASKS
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

create index if not exists idx_tasks_case on tasks(case_id);
create index if not exists idx_tasks_blocking on tasks(case_id,status) where is_blocking=true;

-- unified task state machine
create or replace function enforce_task_state_machine()
returns trigger as $$
begin
    if old.status='completed' and new.status<>'completed' then
        raise exception 'Completed tasks cannot change status';
    end if;

    if new.status='completed' and old.status<>'completed' then
        if new.completed_by is null then
            raise exception 'completed_by required';
        end if;

        if new.completed_at is null then
            new.completed_at := now();
        end if;
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_task_state_machine on tasks;
create trigger trg_task_state_machine
before update on tasks
for each row execute procedure enforce_task_state_machine();


-- =========================================================
-- APPOINTMENTS
-- =========================================================
create table if not exists appointments (
    id uuid primary key default uuid_generate_v4(),
    case_id uuid not null references cases(id) on delete cascade,
    type text not null check (type in ('consultation','biometrics','embassy','medical')),
    scheduled_at timestamptz not null,
    status text not null default 'scheduled'
        check (status in ('scheduled','attended','missed','cancelled')),
    marked_by uuid references users(id),
    created_at timestamptz not null default now()
);

create index if not exists idx_appointments_case on appointments(case_id);

create unique index if not exists uniq_future_biometrics
on appointments(case_id)
where type='biometrics' and status='scheduled';

-- auto mark missed
create or replace function auto_mark_missed_appointments()
returns trigger as $$
begin
    update appointments
    set status='missed'
    where status='scheduled'
    and scheduled_at < now();
    return null;
end;
$$ language plpgsql;

drop trigger if exists trg_auto_missed on cases;
create trigger trg_auto_missed
after update on cases
execute procedure auto_mark_missed_appointments();


-- =========================================================
-- PAYMENTS (dual control)
-- =========================================================
create table if not exists payments (
    id uuid primary key default uuid_generate_v4(),
    case_id uuid not null references cases(id) on delete cascade,
    amount numeric(10,2) not null check (amount>0),
    currency text not null default 'USD',
    recorded_by uuid not null references users(id),
    recorded_at timestamptz not null default now(),
    confirmed_by uuid references users(id),
    confirmed_at timestamptz,
    status text not null default 'pending'
        check (status in ('pending','confirmed','rejected')),
    note text
);

create index if not exists idx_payments_case on payments(case_id);

create or replace function enforce_finance_separation()
returns trigger as $$
begin
    if new.status='confirmed' then
        if new.confirmed_by is null then
            raise exception 'Finance confirmation required';
        end if;

        if new.confirmed_by=new.recorded_by then
            raise exception 'Recorder cannot confirm payment';
        end if;

        if new.confirmed_at is null then
            new.confirmed_at:=now();
        end if;
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_payment_confirmation on payments;
create trigger trg_payment_confirmation
before update on payments
for each row execute procedure enforce_finance_separation();


-- =========================================================
-- READINESS VIEW
-- =========================================================
create or replace view case_ready_for_submission as
select
    c.id as case_id,

    not exists (
        select 1 from tasks t
        where t.case_id=c.id
        and t.is_blocking=true
        and t.status<>'completed'
    )

    and exists (
        select 1 from payments p
        where p.case_id=c.id
        and p.status='confirmed'
    )

    and not exists (
        select 1 from appointments a
        where a.case_id=c.id
        and a.status='missed'
    )

as ready
from cases c;


-- =========================================================
-- HARD SUBMISSION LOCK
-- =========================================================
create or replace function block_illegal_submission()
returns trigger as $$
declare r boolean;
begin
    if new.status_code='submitted' then
        select ready into r
        from case_ready_for_submission
        where case_id=new.id;

        if r is not true then
            raise exception 'Case cannot be submitted: requirements not satisfied';
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_prevent_bad_submission on cases;
create trigger trg_prevent_bad_submission
before insert or update on cases
for each row execute procedure block_illegal_submission();

-- =========================================================
-- END PHASE 4
-- =========================================================