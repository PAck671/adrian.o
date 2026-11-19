-- Pulse & Plan — Supabase schema. Paste into the Supabase SQL editor and run once.
-- shortcut: the app uses only the anon key (no Supabase Auth), so the 6-character couple code is
-- the only secret and the policies below let any anon client read/write. Add Supabase Auth and
-- per-user RLS before sharing the anon key beyond the two of you.

create extension if not exists pgcrypto;

create table if not exists couples (
  code               text primary key check (char_length(code) = 6),
  partner_a          uuid not null,
  partner_b          uuid,
  partner_a_name     text,
  partner_b_name     text,
  visit_date         timestamptz,
  visit_destination  text,
  visit_theme        text,
  created_at         timestamptz not null default now()
);

create table if not exists pulses (
  id           uuid primary key default gen_random_uuid(),
  couple_code  text not null references couples(code) on delete cascade,
  sender_id    uuid not null,
  pattern      text not null,
  duration     double precision not null default 0,
  seen         boolean not null default false,
  created_at   timestamptz not null default now()
);
create index if not exists pulses_unseen on pulses (couple_code, seen);

create table if not exists videos (
  id            uuid primary key default gen_random_uuid(),
  couple_code   text not null references couples(code) on delete cascade,
  sender_id     uuid not null,
  storage_path  text not null,
  duration      double precision not null default 0,
  reaction      text,
  created_at    timestamptz not null default now()
);

create table if not exists movie_swipes (
  couple_code  text not null references couples(code) on delete cascade,
  user_id      uuid not null,
  movie_id     integer not null,
  liked        boolean not null,
  created_at   timestamptz not null default now(),
  primary key (couple_code, user_id, movie_id)
);

create table if not exists game_sessions (
  couple_code  text not null references couples(code) on delete cascade,
  game_code    text not null check (char_length(game_code) = 4),
  game         text not null check (game in ('circuit', 'labyrinth')),
  state        jsonb not null default '{}'::jsonb,
  updated_by   uuid,
  updated_at   timestamptz not null default now(),
  primary key (couple_code, game_code, game)
);

create table if not exists events (
  id           uuid primary key default gen_random_uuid(),
  couple_code  text not null references couples(code) on delete cascade,
  title        text not null,
  kind         text not null check (kind in ('event', 'dateNight', 'busy')),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null check (ends_at > starts_at),
  created_by   uuid not null,
  created_at   timestamptz not null default now()
);

create table if not exists locations (
  couple_code     text not null references couples(code) on delete cascade,
  user_id         uuid not null,
  lat             double precision check (lat between -90 and 90),
  lng             double precision check (lng between -180 and 180),
  precision_mode  text not null check (precision_mode in ('live', 'fuzzy', 'ghost')),
  battery_level   integer check (battery_level between 0 and 100),
  place_label     text,
  city            text,
  updated_at      timestamptz not null default now(),
  primary key (couple_code, user_id)
);

-- Realtime (postgres_changes) for every table the app listens to.
alter publication supabase_realtime add table couples, pulses, videos, movie_swipes, game_sessions, events, locations;

-- Row Level Security: on, with anon-only policies (see shortcut note at the top).
do $$
declare t text;
begin
  foreach t in array array['couples','pulses','videos','movie_swipes','game_sessions','events','locations'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists "anon couple access" on %I', t);
    execute format('create policy "anon couple access" on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

-- Video storage bucket (public read so AVPlayer can stream by URL; 100 MB per clip).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('videos', 'videos', true, 104857600, array['video/quicktime', 'video/mp4'])
on conflict (id) do nothing;

drop policy if exists "anon upload videos" on storage.objects;
create policy "anon upload videos" on storage.objects for insert to anon with check (bucket_id = 'videos');
drop policy if exists "anon read videos" on storage.objects;
create policy "anon read videos" on storage.objects for select to anon using (bucket_id = 'videos');
