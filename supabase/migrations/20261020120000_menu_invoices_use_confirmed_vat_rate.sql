create or replace function public.post_paid_menu_order_to_books_v2()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  seller_organization_id uuid;
  customer_contact_id uuid;
  invoice_uuid uuid;
  tax_uuid uuid;
  customer_name text;
  customer_email text;
  customer_phone text;
  order_subtotal numeric;
  order_tax numeric;
  order_currency char(3);
  order_date date := coalesce(new.created_at::date, current_date);
begin
  if new.payment_status <> 'paid'
     or not (tg_op = 'INSERT' or old.payment_status is distinct from 'paid')
     or new.books_invoice_id is not null then
    return new;
  end if;

  seller_organization_id := new.organization_id;

  if seller_organization_id is null then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'Menu order has no hotel organization'
     where id = new.id;
    return new;
  end if;

  if exists (
    select 1
      from public.menu_order_items order_item
      join public.menu_items item on item.id = order_item.menu_item_id
     where order_item.order_id = new.id
       and item.organization_id is distinct from seller_organization_id
  ) then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'Menu order contains items from another or unmapped hotel'
     where id = new.id;
    return new;
  end if;

  customer_name := nullif(trim(concat_ws(' ', new.first_name, new.last_name)), '');
  customer_email := nullif(trim(new.email), '');
  customer_phone := nullif(trim(new.phone), '');

  if new.user_id is not null then
    select nullif(trim(concat_ws(' ', up.first_name, up.last_name)), ''),
           nullif(trim(up.email), ''),
           nullif(trim(up.phone), '')
      into customer_name, customer_email, customer_phone
      from public.user_profiles up
     where up.user_id = new.user_id;
    customer_name := coalesce(customer_name, nullif(trim(concat_ws(' ', new.first_name, new.last_name)), ''));
    customer_email := coalesce(customer_email, nullif(trim(new.email), ''));
    customer_phone := coalesce(customer_phone, nullif(trim(new.phone), ''));
  end if;

  if customer_email is null then
    update public.menu_orders
       set books_accounting_status = 'failed',
           books_accounting_error = 'A customer email is required for the Books invoice'
     where id = new.id;
    return new;
  end if;

  order_tax := coalesce(new.tax_amount, 0);
  order_subtotal := coalesce(new.subtotal, new.total_amount - order_tax);
  order_currency := upper(coalesce(new.currency, 'USD'))::char(3);

  select rate.id
    into tax_uuid
    from public.books_tax_rates as rate
    join public.books_organizations as organization on organization.id = rate.organization_id
   where rate.organization_id = seller_organization_id
     and rate.country_code = organization.tax_country_code
     and rate.tax_scope = 'invoice'
     and rate.is_active
     and rate.confirmed_at is not null
     and rate.effective_from <= order_date
     and (rate.effective_to is null or rate.effective_to >= order_date)
   order by rate.effective_from desc, rate.confirmed_at desc
   limit 1;

  select id
    into customer_contact_id
    from public.books_contacts
   where organization_id = seller_organization_id
     and lower(email) = lower(customer_email)
     and type in ('customer', 'both')
   order by created_at
   limit 1;

  if customer_contact_id is null then
    insert into public.books_contacts (organization_id, name, type, email, phone)
    values (seller_organization_id, coalesce(customer_name, customer_email), 'customer', customer_email, customer_phone)
    returning id into customer_contact_id;
  else
    update public.books_contacts
       set name = coalesce(customer_name, name),
           phone = coalesce(customer_phone, phone),
           updated_at = now()
     where id = customer_contact_id;
  end if;

  select id
    into invoice_uuid
    from public.books_invoices
   where organization_id = seller_organization_id
     and invoice_number = 'MENU-' || new.order_number;

  if invoice_uuid is null then
    insert into public.books_invoices (
      organization_id, contact_id, invoice_number, issue_date, due_date,
      currency_code, subtotal, tax_amount, tax_rate_id, status, notes
    ) values (
      seller_organization_id, customer_contact_id, 'MENU-' || new.order_number,
      order_date, order_date, order_currency, order_subtotal, order_tax, tax_uuid,
      'paid', 'Digital menu order ' || new.order_number || ' (' || new.id || ')'
    ) returning id into invoice_uuid;
  end if;

  if not exists (select 1 from public.books_invoice_lines where invoice_id = invoice_uuid) then
    insert into public.books_invoice_lines (invoice_id, organization_id, description, quantity, unit_price)
    select invoice_uuid, seller_organization_id, item_name, quantity, unit_price
      from public.menu_order_items
     where order_id = new.id;
  end if;

  update public.menu_orders
     set books_invoice_id = invoice_uuid,
         books_accounting_status = 'posted',
         books_accounting_error = null
   where id = new.id;

  return new;
exception when others then
  update public.menu_orders
     set books_accounting_status = 'failed',
         books_accounting_error = left(sqlerrm, 2000)
   where id = new.id;
  return new;
end;
$$;

revoke all on function public.post_paid_menu_order_to_books_v2() from public;

delete from public.books_tax_rates as rate
 where rate.name like 'Menu sale tax %'
   and rate.confirmed_at is null
   and not exists (
     select 1 from public.books_invoices as invoice where invoice.tax_rate_id = rate.id
   );
