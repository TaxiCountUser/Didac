-- 086_parse_feedback.sql
-- Feedback del parseo por VOZ, para ver en tiempo real dónde la gente corrige
-- (pestaña "Parseig" de Monitorización). Por cada dictado el backend guarda en
-- /transcribe el texto de Whisper y lo que propuso cada etapa (determinista, LLM
-- y resultado final); cuando el usuario GUARDA, la app envía los valores finales
-- y el backend clasifica cada campo corregido:
--   merge          -> el determinista o el LLM tenían el valor bueno, la mezcla no
--   interpretation -> el texto estaba bien pero ninguno lo sacó
--   transcription  -> el valor correcto ni aparece en el texto (Whisper lo oyó mal)
-- Sin guardar = status 'pending' (en el panel, "abandonado" pasado un rato).
-- NO se guarda el audio. Retención 90 días (lo purga el backend).
-- Solo el backend (service_role) inserta/lee.

create table if not exists public.parse_feedback (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid references public.tenants(id) on delete cascade,
  user_id       uuid references public.users(id)   on delete set null,
  language      text,
  raw_text      text,          -- lo que devolvió Whisper
  text          text,          -- tras correctTranscript (lo que se interpretó)
  det           jsonb,         -- resultado del parser determinista
  llm           jsonb,         -- resultado del LLM (null si no se consultó)
  llm_skipped   boolean not null default false,
  llm_error     text,
  llm_ms        int,
  proposed      jsonb,         -- lo que se envió a la app (resultado final)
  saved         jsonb,         -- lo que el usuario guardó (campos comparables)
  corrections   jsonb,         -- { campo: { proposed, saved, stage } } solo los corregidos
  status        text not null default 'pending',  -- pending | saved
  created_at    timestamptz not null default now(),
  saved_at      timestamptz
);
create index if not exists idx_parse_feedback_created on public.parse_feedback(created_at desc);
create index if not exists idx_parse_feedback_tenant  on public.parse_feedback(tenant_id, created_at desc);

grant select, insert, update, delete on public.parse_feedback to service_role;
alter table public.parse_feedback enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
