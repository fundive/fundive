-- bookings, event_vehicles and event_waivers already refuse a NULL event_id
-- through their *_event_present CHECK constraints; the column itself is still
-- declared nullable, so the generated types say `string | null` and every
-- reader has had to filter out rows that cannot exist. app-fundivers' baseline
-- declares the columns NOT NULL, so FunDivers production already has this.
-- The existing CHECK lets Postgres skip the table scan, and setting NOT NULL on
-- a column that has it is a no-op, so this is safe on either kind of database.

alter table public.bookings       alter column event_id set not null;
alter table public.event_vehicles alter column event_id set not null;
alter table public.event_waivers  alter column event_id set not null;
