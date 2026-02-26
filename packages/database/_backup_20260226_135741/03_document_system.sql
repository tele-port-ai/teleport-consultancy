-- =========================================================
-- TELEPORT CONSULTANCY
-- PHASE 3 — DOCUMENT INTELLIGENCE SYSTEM (PRODUCTION SAFE)
-- =========================================================

-- =========================================================
-- DOCUMENT TYPES MASTER
-- =========================================================
create table if not exists document_types (
    id uuid primary key default uuid_generate_v4(),
    code text unique not null,
    name text not null,
    description text,
    is_expirable boolean default false,
    default_validity_days integer,
    created_at timestamptz default now()
);



-- =========================================================
-- PROGRAM REQUIREMENTS TEMPLATE
-- =========================================================
create table if not exists program_document_requirements (
    id uuid primary key default uuid_generate_v4(),
    program_id uuid references visa_programs(id) on delete cascade,
    document_type_id uuid references document_types(id) on delete cascade,

    is_required boolean default true,
    allow_multiple boolean default false,
    requires_translation boolean default false,

    unique(program_id, document_type_id)
);



-- =========================================================
-- CASE CHECKLIST SNAPSHOT
-- Immutable legal record
-- =========================================================
create table if not exists case_document_checklist (
    id uuid primary key default uuid_generate_v4(),

    case_id uuid not null references cases(id) on delete cascade,
    applicant_id uuid references applicants(id), -- null = main applicant

    document_type_id uuid references document_types(id),

    -- SNAPSHOT RULES (important)
    is_required boolean not null,
    allow_multiple boolean not null,
    requires_translation boolean not null,
    is_expirable boolean not null,
    validity_days integer,

    -- STATUS
    status text not null check (status in (
        'missing',
        'uploaded',
        'needs_reupload',
        'approved',
        'expired',
        'waived'
    )) default 'missing',

    last_uploaded_at timestamptz,
    approved_at timestamptz,
    approved_by uuid references users(id),
    rejection_reason text,

    unique(case_id, applicant_id, document_type_id)
);



-- =========================================================
-- DOCUMENT VERSIONS
-- =========================================================
create table if not exists document_versions (
    id uuid primary key default uuid_generate_v4(),
    checklist_id uuid not null references case_document_checklist(id) on delete cascade,

    file_path text not null,
    file_size integer,
    mime_type text,

    uploaded_by uuid references users(id),
    uploaded_at timestamptz default now()
);



-- =========================================================
-- AUTO STATUS UPDATE AFTER UPLOAD
-- =========================================================
create or replace function update_checklist_after_upload()
returns trigger as $$
begin
    update case_document_checklist
    set status = 'uploaded',
        last_uploaded_at = now()
    where id = new.checklist_id
      and status in ('missing','needs_reupload');

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_doc_upload_update on document_versions;
create trigger trg_doc_upload_update
after insert on document_versions
for each row
execute procedure update_checklist_after_upload();



-- =========================================================
-- GENERATE CHECKLIST SNAPSHOT WHEN PROGRAM SELECTED
-- =========================================================
create or replace function generate_case_checklist()
returns trigger as $$
begin

    insert into case_document_checklist(
        case_id,
        applicant_id,
        document_type_id,
        is_required,
        allow_multiple,
        requires_translation,
        is_expirable,
        validity_days
    )
    select
        new.id,
        null,
        dt.id,
        r.is_required,
        r.allow_multiple,
        r.requires_translation,
        dt.is_expirable,
        dt.default_validity_days
    from program_document_requirements r
    join document_types dt on dt.id = r.document_type_id
    where r.program_id = new.program_id
    on conflict do nothing;

    return new;
end;
$$ language plpgsql;

drop trigger if exists trg_generate_checklist on cases;
create trigger trg_generate_checklist
after update of program_id on cases
for each row
when (new.program_id is not null)
execute procedure generate_case_checklist();



-- =========================================================
-- CASE READY FOR SUBMISSION CHECK
-- =========================================================
create or replace function is_case_ready(p_case uuid)
returns boolean as $$
begin
    return not exists (
        select 1
        from case_document_checklist
        where case_id = p_case
        and is_required = true
        and status <> 'approved'
    );
end;
$$ language plpgsql stable;