-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 2 — WORKFLOW ENGINE (AUTOMATION LAYER)
-- Depends on: 01_case_engine_patch.sql
-- Database becomes self-protecting
-- =========================================================



-- =========================================================
-- STATUS TRANSITION MAP (STATE MACHINE RULES)
-- Defines allowed workflow path
-- =========================================================
create table if not exists case_status_transitions (
    from_status text not null references case_statuses(code) on delete cascade,
    to_status   text not null references case_statuses(code) on delete cascade,
    primary key (from_status, to_status)
);


-- --- Allowed lifecycle ---
insert into case_status_transitions values
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



-- =========================================================
-- TRANSITION VALIDATOR
-- Blocks illegal workflow jumps
-- =========================================================
create or replace function validate_case_transition()
returns trigger as $$
begin

    if new.status_code is not distinct from old.status_code then
        return new;
    end if;

    if not exists (
        select 1
        from case_status_transitions
        where from_status = old.status_code
          and to_status   = new.status_code
    ) then
        raise exception
        'Illegal case transition: % → %', old.status_code, new.status_code;
    end if;

    return new;
end;
$$ language plpgsql;


drop trigger if exists trg_validate_transition on cases;
create trigger trg_validate_transition
before update of status_code on cases
for each row
execute procedure validate_case_transition();



-- =========================================================
-- AUTO OPEN DATE
-- Sets first time case becomes officially opened
-- =========================================================
create or replace function auto_set_opened_at()
returns trigger as $$
begin
    if new.status_code = 'case_open'
       and old.opened_at is null then
        new.opened_at := now();
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_auto_open_date on cases;
create trigger trg_auto_open_date
before update on cases
for each row
execute procedure auto_set_opened_at();



-- =========================================================
-- AUTO CLOSE TERMINAL STATES
-- Approved / Not Eligible / Closed etc
-- =========================================================
create or replace function auto_close_case()
returns trigger as $$
declare
    terminal boolean;
begin
    select is_terminal into terminal
    from case_statuses
    where code = new.status_code;

    if terminal = true
       and new.closed_at is null then
        new.closed_at := now();
    end if;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_auto_close on cases;
create trigger trg_auto_close
before update on cases
for each row
execute procedure auto_close_case();



-- =========================================================
-- APPLICATION ATTEMPT SYNCHRONIZATION
-- Embassy decision drives case status
-- Safe: prevents infinite recursion
-- =========================================================
create or replace function sync_attempt_status()
returns trigger as $$
declare
    target_status text;
begin

    target_status :=
        case
            when new.decision = 'approved' then 'approved'
            when new.decision = 'refused'  then 'refused'
            when new.submitted_at is not null then 'submitted'
            else null
        end;

    if target_status is not null then
        update cases
        set status_code = target_status
        where id = new.case_id
          and status_code is distinct from target_status;
    end if;

    return new;
end;
$$ language plpgsql;


drop trigger if exists trg_attempt_sync on application_attempts;
create trigger trg_attempt_sync
after insert or update on application_attempts
for each row
execute procedure sync_attempt_status();



-- =========================================================
-- UPDATED_AT SUPPORT
-- =========================================================
drop trigger if exists trg_cases_updated on cases;
create trigger trg_cases_updated
before update on cases
for each row execute procedure set_updated_at();



-- =========================================================
-- END PHASE 2
-- =========================================================