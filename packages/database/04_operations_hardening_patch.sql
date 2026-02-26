-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 4 HARDENING PATCH
-- Database Level Safety Locks
-- =========================================================

-- =========================================================
-- 1. CASE STATUS TRANSITION GUARD
-- Prevent illegal workflow jumps
-- =========================================================

create table if not exists allowed_case_transitions (
    from_status text references case_statuses(code),
    to_status text references case_statuses(code),
    primary key (from_status, to_status)
);

-- Legit workflow path
insert into allowed_case_transitions values
('lead','assessment'),
('assessment','eligible'),
('assessment','not_eligible'),
('eligible','case_open'),
('case_open','program_selected'),
('program_selected','document_collection'),
('document_collection','submitted'),
('submitted','biometrics'),
('biometrics','decision_pending'),
('decision_pending','approved'),
('decision_pending','refused'),
('approved','closed'),
('refused','closed')
on conflict do nothing;

-- Transition validator
create or replace function enforce_valid_case_transition()
returns trigger as $$
begin
    if old.status_code is distinct from new.status_code then
        if not exists (
            select 1
            from allowed_case_transitions
            where from_status = old.status_code
            and to_status = new.status_code
        ) then
            raise exception
            'Illegal case status transition: % -> %',
            old.status_code, new.status_code;
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_case_transition_guard
before update on cases
for each row execute procedure enforce_valid_case_transition();



-- =========================================================
-- 2. LOCK CLOSED CASES
-- Nothing editable after closure
-- =========================================================

create or replace function prevent_closed_case_modification()
returns trigger as $$
begin
    if old.closed_at is not null then
        raise exception 'Closed cases are immutable';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_lock_closed_case
before update or delete on cases
for each row execute procedure prevent_closed_case_modification();



-- =========================================================
-- 3. FINANCIAL RECORD IMMUTABILITY
-- Payments cannot be changed after confirmation
-- =========================================================

create or replace function lock_confirmed_payments()
returns trigger as $$
begin
    if old.status = 'confirmed' then
        raise exception 'Confirmed payments cannot be modified or deleted';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_lock_confirmed_payment_update
before update on payments
for each row execute procedure lock_confirmed_payments();

create trigger trg_lock_confirmed_payment_delete
before delete on payments
for each row execute procedure lock_confirmed_payments();



-- =========================================================
-- 4. DECISION FREEZE
-- After embassy decision → freeze operational data
-- =========================================================

create or replace function freeze_after_decision()
returns trigger as $$
declare
    decided boolean;
begin
    select exists (
        select 1 from cases
        where id = old.case_id
        and status_code in ('approved','refused','closed')
    ) into decided;

    if decided then
        raise exception 'Case already decided — records locked';
    end if;

    return new;
end;
$$ language plpgsql;

create trigger trg_freeze_tasks
before update or delete on tasks
for each row execute procedure freeze_after_decision();

create trigger trg_freeze_appointments
before update or delete on appointments
for each row execute procedure freeze_after_decision();



-- =========================================================
-- 5. TIMELINE IMMUTABILITY (AUDIT LOG)
-- =========================================================

create or replace function protect_timeline()
returns trigger as $$
begin
    raise exception 'Timeline records cannot be modified or deleted';
end;
$$ language plpgsql;

create trigger trg_protect_timeline_update
before update on case_timeline
for each row execute procedure protect_timeline();

create trigger trg_protect_timeline_delete
before delete on case_timeline
for each row execute procedure protect_timeline();



-- =========================================================
-- 6. PREVENT CASE REOPENING
-- =========================================================

create or replace function prevent_reopen_case()
returns trigger as $$
begin
    if old.status_code in ('approved','refused','closed')
       and new.status_code not in ('approved','refused','closed') then
        raise exception 'Finalized cases cannot be reopened';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_no_reopen_case
before update on cases
for each row execute procedure prevent_reopen_case();


-- =========================================================
-- END HARDENING PATCH
-- =========================================================