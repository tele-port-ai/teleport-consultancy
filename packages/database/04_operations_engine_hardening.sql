-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 4 HARDENING PATCH
-- Real-world operational safety enforcement
-- =========================================================


-- =========================================================
-- 1) CASE MUTEX LOCK (PREVENT DOUBLE SUBMISSION)
-- =========================================================
create or replace function lock_case_for_transition()
returns trigger as $$
begin
    -- advisory lock per case
    perform pg_advisory_xact_lock(hashtext(new.id::text));
    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_case_transition_lock on cases;
create trigger trg_case_transition_lock
before update on cases
for each row execute procedure lock_case_for_transition();



-- =========================================================
-- 2) FINAL CASE IMMUTABILITY
-- No modification after terminal state
-- =========================================================
create or replace function block_terminal_case_modifications()
returns trigger as $$
declare terminal boolean;
begin
    select is_terminal into terminal
    from case_statuses
    where code = old.status_code;

    if terminal then
        raise exception 'Case is closed and cannot be modified';
    end if;

    return new;
end;
$$ language plpgsql;

create trigger trg_block_terminal_case_updates
before update on cases
for each row execute procedure block_terminal_case_modifications();



-- =========================================================
-- 3) TASK INSERT VALIDATION
-- Prevent bypassing completion rules
-- =========================================================
create or replace function validate_task_insert()
returns trigger as $$
begin
    if new.status='completed' then
        if new.completed_by is null then
            raise exception 'completed_by required on insert';
        end if;

        if new.completed_at is null then
            new.completed_at := now();
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_validate_task_insert
before insert on tasks
for each row execute procedure validate_task_insert();



-- =========================================================
-- 4) PAYMENT ACCOUNTING IMMUTABILITY
-- Confirmed payments cannot change
-- =========================================================
create or replace function lock_confirmed_payment()
returns trigger as $$
begin
    if old.status='confirmed' then
        raise exception
        'Confirmed payments cannot be modified. Create adjustment entry.';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_lock_confirmed_payment
before update on payments
for each row execute procedure lock_confirmed_payment();



-- =========================================================
-- 5) APPOINTMENT TIME FREEZE
-- Past events are immutable
-- =========================================================
create or replace function freeze_past_appointments()
returns trigger as $$
begin
    if old.scheduled_at < now() then
        raise exception 'Past appointments cannot be edited';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_freeze_past_appointments
before update on appointments
for each row execute procedure freeze_past_appointments();



-- =========================================================
-- 6) BLOCK DATA CREATION ON CLOSED CASE
-- =========================================================
create or replace function block_child_records_closed_case()
returns trigger as $$
declare terminal boolean;
begin
    select cs.is_terminal into terminal
    from cases c
    join case_statuses cs on cs.code=c.status_code
    where c.id=new.case_id;

    if terminal then
        raise exception 'Cannot modify closed case';
    end if;

    return new;
end;
$$ language plpgsql;


create trigger trg_no_tasks_closed_case
before insert on tasks
for each row execute procedure block_child_records_closed_case();

create trigger trg_no_payments_closed_case
before insert on payments
for each row execute procedure block_child_records_closed_case();

create trigger trg_no_appointments_closed_case
before insert on appointments
for each row execute procedure block_child_records_closed_case();



-- =========================================================
-- END HARDENING
-- =========================================================