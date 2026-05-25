-- Public bucket for 2D outfit frames (single-PNG outfits saved from the
-- new 2D-vs-3D fork). Each 2D outfit has exactly one frame at
-- <userId>/<outfit-id>/00000.png so the existing Outfit.framePath /
-- frameURL plumbing keeps working: folder = <outfit-id>, prefix = "",
-- frame_ext = "png", remote_base_url = <bucket-public-base>/<userId>.

-- ============================================================
-- Bucket
-- ============================================================

insert into storage.buckets (id, name, public)
values ('outfit-2d-frames', 'outfit-2d-frames', true)
on conflict (id) do nothing;

-- ============================================================
-- Policies
-- ============================================================

-- Anyone can read. The bucket is public so the feed/profile views can
-- render 2D outfits from other users without signed URLs.
drop policy if exists "outfit_2d_frames_public_read" on storage.objects;
create policy "outfit_2d_frames_public_read"
on storage.objects for select
to public
using (bucket_id = 'outfit-2d-frames');

-- Authenticated users may only write into their own folder
-- (<userId>/...) so one user can't overwrite another's frames.
drop policy if exists "outfit_2d_frames_owner_insert" on storage.objects;
create policy "outfit_2d_frames_owner_insert"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'outfit-2d-frames'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "outfit_2d_frames_owner_update" on storage.objects;
create policy "outfit_2d_frames_owner_update"
on storage.objects for update
to authenticated
using (
  bucket_id = 'outfit-2d-frames'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "outfit_2d_frames_owner_delete" on storage.objects;
create policy "outfit_2d_frames_owner_delete"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'outfit-2d-frames'
  and (storage.foldername(name))[1] = auth.uid()::text
);
