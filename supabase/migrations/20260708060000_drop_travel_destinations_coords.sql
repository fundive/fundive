-- Drop the lat/long columns from travel_destinations — the app doesn't use
-- geocoordinates for destinations. The Bubble import carried `latitude` and
-- `longitude` that nothing reads (no FK/column reference, no view).

begin;

alter table public.travel_destinations drop column if exists longitude;
alter table public.travel_destinations drop column if exists latitude;

commit;

notify pgrst, 'reload schema';
