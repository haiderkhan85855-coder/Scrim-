begin;

-- Extend the existing stage identity; do not create a second stage table or
-- replace UUIDs already referenced by lobbies, matches and financial history.
alter table public.tournament_stages
  add column name_preset text,
  add column custom_name text;

-- Preserve both the displayed historical names and their original timestamps.
-- This exact timestamp trigger is suspended only within this DDL transaction.
alter table public.tournament_stages
  disable trigger tournament_stages_set_updated_at;

update public.tournament_stages
set
  name_preset = case display_name
    when 'Open Qualifier' then 'open_qualifier'
    when 'Qualifier' then 'qualifier'
    when 'Quarterfinal' then 'quarterfinal'
    when 'Semifinal' then 'semifinal'
    when 'Grand Final' then 'grand_final'
    else 'qualifier'
  end,
  custom_name = case
    when display_name in (
      'Open Qualifier', 'Qualifier', 'Quarterfinal', 'Semifinal', 'Grand Final'
    ) then null
    else display_name
  end;

alter table public.tournament_stages
  enable trigger tournament_stages_set_updated_at;

alter table public.tournament_stages
  alter column name_preset set not null,
  add constraint tournament_stages_name_preset_valid check (
    name_preset in (
      'open_qualifier', 'qualifier', 'quarterfinal', 'semifinal', 'grand_final'
    )
  ),
  add constraint tournament_stages_custom_name_valid check (
    custom_name is null or (
      custom_name = btrim(custom_name)
      and char_length(custom_name) between 1 and 100
    )
  ),
  add constraint tournament_stages_display_name_consistent check (
    display_name = coalesce(custom_name, case name_preset
      when 'open_qualifier' then 'Open Qualifier'
      when 'qualifier' then 'Qualifier'
      when 'quarterfinal' then 'Quarterfinal'
      when 'semifinal' then 'Semifinal'
      when 'grand_final' then 'Grand Final'
    end)
  );

create function public.levelledup_guard_stage_identity_and_name()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  preset_display_name text;
begin
  if tg_op = 'DELETE' then
    raise exception 'Permanent tournament stages cannot be deleted. Retire the stage using its cancelled status.'
      using errcode = '22023';
  end if;

  if tg_op = 'UPDATE' then
    if new.id is distinct from old.id
      or new.tournament_id is distinct from old.tournament_id
      or new.created_at is distinct from old.created_at then
      raise exception 'Stage identity, tournament ownership and creation timestamp are permanent.'
        using errcode = '22023';
    end if;

    if new.display_name is distinct from old.display_name
      and new.name_preset is not distinct from old.name_preset
      and new.custom_name is not distinct from old.custom_name then
      raise exception 'Set the stage name preset or custom name instead of changing the derived display name.'
        using errcode = '22023';
    end if;
  end if;

  -- Keep existing trusted INSERT statements that supply only display_name
  -- compatible. New writers may supply name_preset/custom_name and omit it.
  if tg_op = 'INSERT' and new.name_preset is null then
    new.name_preset := case new.display_name
      when 'Open Qualifier' then 'open_qualifier'
      when 'Quarterfinal' then 'quarterfinal'
      when 'Semifinal' then 'semifinal'
      when 'Grand Final' then 'grand_final'
      else 'qualifier'
    end;
    if new.display_name is not null and new.display_name not in (
      'Open Qualifier', 'Qualifier', 'Quarterfinal', 'Semifinal', 'Grand Final'
    ) then
      new.custom_name := coalesce(new.custom_name, new.display_name);
    end if;
  end if;

  preset_display_name := case new.name_preset
    when 'open_qualifier' then 'Open Qualifier'
    when 'qualifier' then 'Qualifier'
    when 'quarterfinal' then 'Quarterfinal'
    when 'semifinal' then 'Semifinal'
    when 'grand_final' then 'Grand Final'
  end;
  if preset_display_name is null then
    raise exception 'Choose a supported tournament stage name preset.'
      using errcode = '22023';
  end if;

  new.custom_name := nullif(btrim(new.custom_name), '');
  new.display_name := coalesce(new.custom_name, preset_display_name);
  return new;
end;
$$;

alter function public.levelledup_guard_stage_identity_and_name() owner to postgres;
revoke all on function public.levelledup_guard_stage_identity_and_name()
  from public, anon, authenticated;

create trigger tournament_stages_00_guard_identity_and_name
before insert or update or delete on public.tournament_stages
for each row execute function public.levelledup_guard_stage_identity_and_name();

comment on column public.tournament_stages.id is
  'Permanent globally unique Stage ID (UUID), independent of name or order. Cannot be changed, re-parented or deleted; all existing references retain this identity.';
comment on column public.tournament_stages.tournament_id is
  'The one permanent owning tournament. Existing (id, tournament_id) keys enforce tournament scope throughout lobbies and financial references; matches are scoped through their lobby.';
comment on column public.tournament_stages.stage_number is
  'Positive tournament-local order, unique within the tournament, not a public name or identity. Presets are independent of order; stages may be skipped and order gaps are allowed.';
comment on column public.tournament_stages.name_preset is
  'Professional stage category: open_qualifier, qualifier, quarterfinal, semifinal or grand_final. No mandatory sequence or one-of-each restriction.';
comment on column public.tournament_stages.custom_name is
  'Optional display-name override, up to 100 characters. Legacy non-preset stage names are retained here without inferring progression rules.';
comment on column public.tournament_stages.display_name is
  'Compatibility display field derived from custom_name or name_preset. Existing slot boards and queries continue reading this field.';

-- Existing RLS/SELECT grants remain unchanged. This migration adds no client
-- mutation privileges, Admin UI, stage creation RPC or progression automation.
commit;
