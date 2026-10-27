-- RoomTwin accounts: the objects each user scans and saves. A row per object
-- here, and its files in the private "objects" bucket under a folder named
-- after the user's ID. Row-level security keeps everyone to their own, which
-- is what makes it safe for the app to carry the public (anon) key.
-- Safe to run again: Accounts/setup_supabase.py applies it on every run.

create table if not exists public.objects (
    id uuid primary key default gen_random_uuid(),
    owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
    name text not null check (char_length(name) between 1 and 80),
    model_path text not null,
    thumb_path text,
    created_at timestamptz not null default now()
);
alter table public.objects enable row level security;
grant select, insert, delete on public.objects to authenticated;

drop policy if exists "own objects: read" on public.objects;
create policy "own objects: read" on public.objects
    for select to authenticated using (owner = auth.uid());
drop policy if exists "own objects: add" on public.objects;
create policy "own objects: add" on public.objects
    for insert to authenticated with check (owner = auth.uid());
drop policy if exists "own objects: delete" on public.objects;
create policy "own objects: delete" on public.objects
    for delete to authenticated using (owner = auth.uid());

-- Private, up to 50 MB a file (an Object Capture model is usually 5–30 MB).
insert into storage.buckets (id, name, public, file_size_limit)
values ('objects', 'objects', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

drop policy if exists "own object files: read" on storage.objects;
create policy "own object files: read" on storage.objects
    for select to authenticated
    using (bucket_id = 'objects' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own object files: add" on storage.objects;
create policy "own object files: add" on storage.objects
    for insert to authenticated
    with check (bucket_id = 'objects' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own object files: delete" on storage.objects;
create policy "own object files: delete" on storage.objects
    for delete to authenticated
    using (bucket_id = 'objects' and (storage.foldername(name))[1] = auth.uid()::text);

-- Saved RoomPlan layouts. The model is the edited USDZ shown in Orbit/Walk;
-- PLY is the raw vertex-colour geometry and JSON keeps RoomPlan's semantic
-- walls, openings and furniture data.
create table if not exists public.room_layouts (
    id uuid primary key default gen_random_uuid(),
    owner uuid not null default auth.uid() references auth.users (id) on delete cascade,
    name text not null check (char_length(name) between 1 and 80),
    model_path text not null,
    ply_path text not null,
    json_path text not null,
    edits_path text,
    created_at timestamptz not null default now()
);
-- Backward-compatible migration for projects created before edit metadata.
alter table public.room_layouts add column if not exists edits_path text;
alter table public.room_layouts enable row level security;
grant select, insert, delete on public.room_layouts to authenticated;

drop policy if exists "own room layouts: read" on public.room_layouts;
create policy "own room layouts: read" on public.room_layouts
    for select to authenticated using (owner = auth.uid());
drop policy if exists "own room layouts: add" on public.room_layouts;
create policy "own room layouts: add" on public.room_layouts
    for insert to authenticated with check (owner = auth.uid());
drop policy if exists "own room layouts: delete" on public.room_layouts;
create policy "own room layouts: delete" on public.room_layouts
    for delete to authenticated using (owner = auth.uid());

-- Kept for rooms saved by older builds. New builds send complete room files
-- through the RoomTwin backend to the owner's Google Drive and store paths here.
insert into storage.buckets (id, name, public, file_size_limit)
values ('room-layouts', 'room-layouts', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

drop policy if exists "own room layout files: read" on storage.objects;
create policy "own room layout files: read" on storage.objects
    for select to authenticated
    using (bucket_id = 'room-layouts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own room layout files: add" on storage.objects;
create policy "own room layout files: add" on storage.objects
    for insert to authenticated
    with check (bucket_id = 'room-layouts' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "own room layout files: delete" on storage.objects;
create policy "own room layout files: delete" on storage.objects
    for delete to authenticated
    using (bucket_id = 'room-layouts' and (storage.foldername(name))[1] = auth.uid()::text);
