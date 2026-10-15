-- RHINO Restores on the Social tab, next to HAGGERTY.
-- Applied to Supabase on 2026-10-15 in the SQL editor. Kept here as the record.
--
-- Nothing new to build: social_posts, social_post_media, social_jobs,
-- social_results and social_settings already carry a brand column. The
-- dashboard's brand switch picks 'haggerty' or 'rhino', and everything on
-- the tab (posts, jobs, results, target mix) follows it.
--
-- Metricool brands: haggerty = 5357410, rhino = 6222867 (Instagram
-- rhinorestores, Facebook, LinkedIn org 112983450). The send and results
-- routines pick the brand from the row (sql/social_send.sql,
-- sql/social_results.sql). RHINO media is stored under rhino/ in the
-- social-media bucket so its folder names never collide with HAGGERTY's.

-- 1. RHINO has its own focus list (what a post is about).
alter table public.social_posts drop constraint if exists social_posts_focus_check;
alter table public.social_posts add constraint social_posts_focus_check
  check (focus is null or focus = any (array[
    'projects','people','events','holidays','services','company','throwbacks',  -- HAGGERTY
    'fire','water','mold','storm','contents','tips']));                         -- RHINO adds
-- 2. Only the two brands.
alter table public.social_posts add constraint social_posts_brand_check
  check (brand = any (array['haggerty','rhino'])) not valid;
-- 3. RHINO's target mix row.
insert into public.social_settings (brand) values ('rhino') on conflict do nothing;

-- 4. What the laptop task (generate and extras) needs for RHINO.
--    Add to its instructions:
--      Every social_jobs row has a brand. For brand 'haggerty' keep doing
--      what you do today. For brand 'rhino' (RHINO Restores):
--      - Pick media only from C:\Users\Liam\Documents\Ai Projects\
--        Marketing Application\Restoration (connect it to the task). Each
--        subfolder is one job (Colma, Mission, Mountain House, Wetzel, ...);
--        build a post from one job's photos. Loose files at the top level
--        are brochures, team and drone shots for people/company posts.
--        Use .jpg/.png/.mp4/.mov only; skip .DNG, .zip and Thumbs.db.
--        Skip a photo already used by a RHINO social_posts row
--        (social_post_media.source_path). Never use HAGGERTY photos.
--      - Write as RHINO Restores, a division of HAGGERTY Construction:
--        fire, water, mold, storm and contents restoration across Northern
--        California, the Central Valley and the Bay Area. IICRC certified,
--        24/7, about 30 minute response, mitigation through rebuild with one
--        team ("We Own The Job"). Plain, calm, practical: open with one short
--        line about the loss, explain what the crew is doing and why, end
--        with "Fire, water, mold. We answer 24/7." or the phone number
--        209-323-6200. Instagram/Facebook caption short; LinkedIn
--        (tags_li post) longer, written for property managers, adjusters
--        and commercial owners.
--      - Hashtags: #RHINORestores plus the loss type (#FireDamage,
--        #WaterDamage, #MoldRemediation, #StormDamage, #ContentsPackout)
--        and place (#StocktonCA #NorCal #CentralValley).
--      - focus is one of fire, water, mold, storm, contents, tips, people,
--        events, holidays, company. Follow options.mix the same way.
--      - Save to a separate RHINO month folder with its own plan.json, so
--        it is imported while the Social tab is switched to RHINO.
