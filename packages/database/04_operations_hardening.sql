-- =========================================================
-- IMMUTABLE RECORD GUARD
-- prevents silent history corruption
-- =========================================================

create or replace function prevent_update_delete()
returns trigger as $$
begin
    raise exception 'Historical records cannot be modified or deleted';
end;
$$ language plpgsql;


create trigger trg_lock_case_timeline
before update or delete on case_timeline
for each row execute procedure prevent_update_delete();


create trigger trg_lock_attempts
before update or delete on application_attempts
for each row execute procedure prevent_update_delete();


create or replace function prevent_closed_case_edit()
returns trigger as $$
begin
    if old.status_code in ('approved','refused','closed') then
        raise exception 'Closed/Decided cases are read-only';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_lock_closed_case
before update on cases
for each row execute procedure prevent_closed_case_edit();


create trigger trg_lock_payments
before delete on payments
for each row execute procedure prevent_update_delete();



create or replace function block_document_change_after_submission()
returns trigger as $$
declare
    submitted boolean;
begin
    select exists(
        select 1 from cases c
        join application_attempts a on a.case_id=c.id
        where c.id=new.owner_id
        and a.submitted_at is not null
    ) into submitted;

    if submitted then
        raise exception 'Documents locked after submission';
    end if;

    return new;
end;
$$ language plpgsql;

create trigger trg_lock_documents_after_submit
before update or delete on documents
for each row
when (old.owner_type='case')
execute procedure block_document_change_after_submission();


create table if not exists allowed_status_transitions (
    from_status text,
    to_status text,
    primary key (from_status,to_status)
);


insert into allowed_status_transitions values
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
('refused','document_collection')
on conflict do nothing;


create or replace function enforce_status_transition()
returns trigger as $$
begin
    if old.status_code is distinct from new.status_code then
        if not exists (
            select 1 from allowed_status_transitions
            where from_status = old.status_code
            and to_status = new.status_code
        ) then
            raise exception 'Illegal case status transition: % -> %',
                old.status_code,new.status_code;
        end if;
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_enforce_status_transition
before update on cases
for each row execute procedure enforce_status_transition();


create or replace function enforce_case_assignment()
returns trigger as $$
begin
    if new.assigned_consultant is not null
       and current_setting('request.jwt.claim.role', true) = 'client' then
        raise exception 'Clients cannot modify case data';
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_case_assignment_guard
before update on cases
for each row execute procedure enforce_case_assignment();


create or replace function auto_close_after_approval()
returns trigger as $$
begin
    if new.status_code='approved' then
        new.closed_at := now();
    end if;
    return new;
end;
$$ language plpgsql;

create trigger trg_auto_close_case
before update on cases
for each row execute procedure auto_close_after_approval();