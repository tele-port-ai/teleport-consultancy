-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 1 — CASE ENGINE (BUSINESS LAYER)
-- Production Safe Version
-- Depends on: 00_base_schema.sql
-- =========================================================

-- =========================================================
-- CASE STATUS MASTER (STATE MACHINE)
-- =========================================================
create table if not exists case_statuses (
code text primary key,
description text not null,
is_terminal boolean not null default false
);

insert into case_statuses (code, description, is_terminal) values
('lead','New inquiry',false),
('assessment','Eligibility evaluation',false),
('eligible','Client eligible',false),
('not_eligible','Client not eligible',true),
('case_open','Case officially opened',false),
('program_selected','Visa program selected',false),
('document_collection','Collecting documents',false),
('submitted','Submitted to embassy',false),
('biometrics','Biometrics required/done',false),
('decision_pending','Waiting decision',false),
('approved','Visa approved',true),
('refused','Visa refused',true),
('closed','Case closed',true)
on conflict do nothing;

-- =========================================================
-- WORKFLOW TRANSITIONS (STRICT STATE MACHINE)
-- =========================================================
create table if not exists case_status_transitions (
from_status text references case_statuses(code) on delete cascade,
to_status text references case_statuses(code) on delete cascade,
primary key(from_status, to_status)
);

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
-- VISA PROGRAMS (VERSIONED CONFIG DATA)
-- =========================================================
create table if not exists visa_programs (
id uuid primary key default uuid_generate_v4(),
country text not null,
program_name text not null,
category text,
processing_time_days integer,
embassy_fee numeric(10,2),
consultancy_fee numeric(10,2),
currency text default 'USD',
program_year integer default extract(year from now()),
is_active boolean not null default true,
created_at timestamptz not null default now(),
updated_at timestamptz not null default now()
);

create unique index if not exists visa_program_unique_version
on visa_programs(country, program_name, program_year);

create index if not exists idx_program_active on visa_programs(is_active);

-- =========================================================
-- CASES (ONE ACTIVE PER CLIENT)
-- =========================================================
create table if not exists cases (
id uuid primary key default uuid_generate_v4(),

identity_id uuid not null
    references identity_profiles(id) on delete cascade,

program_id uuid references visa_programs(id),

status_code text not null
    references case_statuses(code),

assigned_consultant uuid references users(id),

priority text check (priority in ('low','normal','high','urgent')) default 'normal',

opened_at timestamptz,
closed_at timestamptz,

notes text,

created_at timestamptz not null default now(),
updated_at timestamptz not null default now(),

constraint closed_requires_terminal
check (
    closed_at is null
    or status_code in ('approved','refused','closed','not_eligible')
)

);

create unique index if not exists one_active_case_per_client
on cases(identity_id)
where closed_at is null;

create index if not exists idx_cases_status on cases(status_code);
create index if not exists idx_cases_consultant on cases(assigned_consultant);

-- =========================================================
-- APPLICATION ATTEMPTS (SUBMISSIONS)
-- =========================================================
create table if not exists application_attempts (
id uuid primary key default uuid_generate_v4(),

case_id uuid not null
    references cases(id) on delete cascade,

attempt_number integer not null,
submitted_at timestamptz,
decision_at timestamptz,

decision text check (decision in ('approved','refused','withdrawn')),

refusal_reason text,
embassy_reference text,

created_at timestamptz not null default now(),

unique(case_id, attempt_number)

);

create index if not exists idx_attempt_case on application_attempts(case_id);

-- =========================================================
-- CASE TIMELINE (LEGAL AUDIT HISTORY — NEVER DELETE)
-- =========================================================
create table if not exists case_timeline (
id bigserial primary key,

case_id uuid not null references cases(id) on delete cascade,

previous_status text references case_statuses(code),
new_status text not null references case_statuses(code),

changed_by uuid references users(id),

change_note text,

created_at timestamptz not null default now()

);

create index if not exists idx_timeline_case on case_timeline(case_id);

-- =========================================================
-- AUDIT TRIGGER (COURT SAFE)
-- Reads application user from: SET app.user_id = 'uuid'
-- =========================================================
create or replace function log_case_status_change()
returns trigger as $$
declare
actor uuid;
begin
begin
actor := current_setting('app.user_id', true)::uuid;
exception
when others then actor := null;
end;

if new.status_code is distinct from old.status_code then
    insert into case_timeline(case_id, previous_status, new_status, changed_by)
    values (old.id, old.status_code, new.status_code, actor);
end if;

return new;

end;
$$ language plpgsql;

drop trigger if exists trg_case_status_history on cases;
create trigger trg_case_status_history
after update on cases
for each row
execute procedure log_case_status_change();

-- =========================================================
-- UPDATED_AT SUPPORT
-- =========================================================
create trigger trg_cases_updated before update on cases
for each row execute procedure set_updated_at();

create trigger trg_programs_updated before update on visa_programs
for each row execute procedure set_updated_at();

-- =========================================================
-- END PHASE 1
-- =========================================================