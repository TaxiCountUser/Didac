-- ============================================================
-- TaxiCount - Asistente virtual (bot de preguntas frecuentes, SIN IA).
--
-- La base de conocimiento "semilla" vive en la app (assets/assistant/kb.json).
-- Aquí se guarda lo que el bot APRENDE y lo que el admin le enseña:
--   assistant_entries : respuestas creadas/editadas desde el panel admin. Si el id
--                       coincide con una entrada del JSON, la SUSTITUYE (override).
--   assistant_learned : frases que apuntan a una respuesta. 'auto' = aprendida sola
--                       (el usuario no fue entendido, reformuló, y dijo "me ha
--                       servido"); 'admin' = el admin enseñó la frase a mano.
--   assistant_queries : registro de cada pregunta (para ver qué NO sabe responder).
--                       Retención 180 días (lo purga el backend).
-- Solo el backend (service_role) accede: la app pasa por /api/v1/assistant/*.
-- ============================================================

create table if not exists public.assistant_entries (
  id          text primary key,                 -- slug (p.ej. 'close_shift')
  data        jsonb not null,                   -- {cat, roles, q:{es,ca,en}, a:{es,ca,en}, action, tutorial}
  active      boolean not null default true,    -- false = ocultar (también una de la semilla)
  updated_by  uuid references public.users(id) on delete set null,
  updated_at  timestamptz not null default now()
);

create table if not exists public.assistant_learned (
  id          uuid primary key default gen_random_uuid(),
  phrase      text not null,                    -- frase NORMALIZADA (minúsculas, sin acentos)
  entry_id    text not null,
  lang        text,
  source      text not null default 'auto',     -- auto | admin
  hits        int  not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (phrase, entry_id)
);
create index if not exists idx_assistant_learned_entry on public.assistant_learned(entry_id);

create table if not exists public.assistant_queries (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid,
  tenant_id       uuid references public.tenants(id) on delete cascade,
  user_id         uuid references public.users(id)   on delete set null,
  role            text,
  lang            text,
  question        text not null,
  phrase          text,                          -- normalizada (para agrupar)
  matched_id      text,                          -- respuesta dada (null = no entendió)
  score           real,
  outcome         text not null default 'answered', -- answered | no_match | helpful | not_helpful | ticket
  created_at      timestamptz not null default now()
);
create index if not exists idx_assistant_queries_created on public.assistant_queries(created_at desc);
create index if not exists idx_assistant_queries_phrase  on public.assistant_queries(phrase);

grant select, insert, update, delete on public.assistant_entries, public.assistant_learned,
  public.assistant_queries to service_role;
alter table public.assistant_entries enable row level security;
alter table public.assistant_learned enable row level security;
alter table public.assistant_queries enable row level security;
-- Sin políticas para authenticated: solo el backend con service_role accede.
