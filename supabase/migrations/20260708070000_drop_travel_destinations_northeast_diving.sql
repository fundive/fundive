-- Drop travel_destinations.northeast_diving. It flagged a destination as a
-- Northeast-coast shore site to drive the calendar's local(green)/trip(yellow)
-- colour; that rule now keys off `divetype` alone — only 'Shore Diving'
-- destinations colour a dive local (see src/lib/event-colors.ts).

begin;

alter table public.travel_destinations drop column if exists northeast_diving;

commit;

notify pgrst, 'reload schema';
