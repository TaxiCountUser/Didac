-- ============================================================================
-- 053_users_tenant_ondelete_setnull.sql
--
-- El admin de plataforma (y cualquier usuario) NO debe desaparecer al borrar una
-- empresa. El FK users.tenant_id estaba en ON DELETE CASCADE, así que borrar un
-- tenant borraba a sus usuarios (incluido el admin si estaba en ese tenant).
-- Se cambia a ON DELETE SET NULL: borrar una empresa deja a sus usuarios sin
-- empresa (tenant_id = null) en vez de eliminarlos. tenant_id ya es nullable.
-- Idempotente (localiza el nombre real del constraint).
-- ============================================================================
do $$
declare c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'public.users'::regclass and contype = 'f'
     and (select attname from pg_attribute
            where attrelid = conrelid and attnum = conkey[1]) = 'tenant_id';
  if c is not null then
    execute format('alter table public.users drop constraint %I', c);
  end if;
end $$;

alter table public.users
  add constraint users_tenant_id_fkey
  foreign key (tenant_id) references public.tenants(id)
  on delete set null on update cascade;

notify pgrst, 'reload schema';
