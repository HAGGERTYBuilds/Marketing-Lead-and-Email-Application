-- Video edit instructions on the Social tab.
-- Applied to Supabase on 2026-10-15 as migration 24_social_video_edit.
--
-- The laptop task already edits every video itself: it picks clips from the
-- archive, trims them, crops them to vertical and joins them, and records
-- the cuts in reel_sources.json in the month folder. Until now nothing told
-- it how Liam wants them cut. Two things do now:
--   social_settings.video_style  the brand's standing preferences, sent on
--                                every generate, extras and reedit job as
--                                options.video_style.
--   social_posts.edit_notes      what to do with one post's video.
-- "Save and re-edit video" on a post queues a social_jobs row of kind
-- 'reedit' with options = {post_id, folder, file, source_path,
-- storage_path, notes, video_style}. The laptop cuts a new version, saves
-- it in the month folder and marks the job ready with the file's path in
-- note. Replace on the post's video brings it in and closes the job.

set lock_timeout = '5s';
alter table public.social_posts add column if not exists edit_notes text;
alter table public.social_settings add column if not exists video_style text;
alter table public.social_jobs drop constraint if exists social_jobs_kind_check;
alter table public.social_jobs add constraint social_jobs_kind_check
  check (kind = any (array['generate','send','extras','send_cloud','reedit']));

-- What the laptop task (generate and extras) needs. Add to its instructions:
--
--   VIDEO EDITING
--   When you cut a video for a post (generate or extras), follow
--   options.video_style on the job if it is there. It is Liam's standing
--   preference for that brand (length, pace, what to leave out, sound,
--   text on screen, opening and ending) and wins over your own defaults.
--   Keep writing reel_sources.json in the month folder for every video,
--   with each segment's source file, start, end and crop, for HAGGERTY and
--   RHINO alike, so a video can be re-cut later.
--
--   RE-EDIT JOBS
--   Also pick up social_jobs rows with kind 'reedit' and status 'pending'.
--   Set status 'running' and started_at when you start. options holds:
--     post_id       the social_posts row
--     folder, file  the post's folder and video file in the month folder
--                   (month = the job's month; RHINO months are under
--                   Restoration\Social\<YYYY-MM>)
--     notes         how Liam wants this video edited (cuts, order,
--                   length, sound, text on screen)
--     video_style   the brand's standing preferences
--   1. Find the original clips in reel_sources.json in that month folder
--      (the entry whose file matches folder\file). If there is no entry,
--      work from the video file itself.
--   2. Cut a new version from the original clips, following notes first
--      and video_style for anything notes do not mention. Things to cut out
--      mean those moments must not appear at all. Keep it 1080x1920 MP4
--      (H.264, AAC), under 50 MB.
--   3. Save it next to the old one as <file name>-v2.mp4 (v3, v4 ... if that
--      exists) and update that entry in reel_sources.json.
--   4. Set status 'ready', finished_at now, and note = the new file's full
--      path plus one short line on what you changed. The dashboard tells
--      Liam to Replace the video with it. If you cannot do what the notes
--      ask (for example the clip they describe is not in the sources), set
--      status 'failed' and say why in note.
--   Never change social_posts or upload anything for a re-edit.
