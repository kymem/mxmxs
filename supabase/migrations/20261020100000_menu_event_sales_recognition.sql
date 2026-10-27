create or replace function public.post_sales_invoice_recognition(target_invoice_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  invoice_row public.books_invoices%rowtype;
  owner_user_id uuid;
  journal_id uuid;
  receivable_id uuid;
  revenue_id uuid;
  vat_payable_id uuid;
  other_charges_account_code text;
  other_charges_account_id uuid;
begin
  select * into invoice_row from public.books_invoices where id = target_invoice_id;
  if not found or invoice_row.status <> 'paid' or invoice_row.invoice_number !~ '^(HOTEL|MENU|EVENT)-' then return; end if;
  if exists (
    select 1 from public.books_journal_transactions
     where organization_id = invoice_row.organization_id
       and source_type in ('hotel_invoice_recognition', 'sales_invoice_recognition')
       and source_id = invoice_row.id
  ) then return; end if;

  select owner_id into owner_user_id from public.books_organizations where id = invoice_row.organization_id;
  insert into public.books_accounts (organization_id, code, name, type, is_system)
  values
    (invoice_row.organization_id, '1000', 'Cash and bank', 'asset', true),
    (invoice_row.organization_id, '1100', 'Accounts receivable', 'asset', true),
    (invoice_row.organization_id, '2100', 'VAT payable', 'liability', true),
    (invoice_row.organization_id, '2200', 'Local hotel tax payable', 'liability', true),
    (invoice_row.organization_id, '2300', 'Service fees and tips payable', 'liability', true),
    (invoice_row.organization_id, '4000', 'Sales revenue', 'income', true)
  on conflict (organization_id, code) do nothing;

  other_charges_account_code := case when invoice_row.invoice_number like 'HOTEL-%' then '2200' else '2300' end;
  select id into receivable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '1100' and type = 'asset';
  select id into revenue_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '4000' and type = 'income';
  select id into vat_payable_id from public.books_accounts where organization_id = invoice_row.organization_id and code = '2100' and type = 'liability';
  select id into other_charges_account_id from public.books_accounts where organization_id = invoice_row.organization_id and code = other_charges_account_code and type = 'liability';
  if receivable_id is null or revenue_id is null or vat_payable_id is null or other_charges_account_id is null then
    raise exception 'Required Books accounts are missing for the sales invoice';
  end if;

  insert into public.books_journal_transactions (organization_id, source_type, source_id, transaction_date, description, created_by)
  values (invoice_row.organization_id, 'sales_invoice_recognition', invoice_row.id, invoice_row.issue_date, 'Recognize sales invoice ' || invoice_row.invoice_number, owner_user_id)
  on conflict do nothing returning id into journal_id;
  if journal_id is null then return; end if;

  insert into public.books_journal_lines (transaction_id, account_id, debit, currency_code)
  values (journal_id, receivable_id, invoice_row.subtotal + invoice_row.tax_amount + invoice_row.other_charges, invoice_row.currency_code);
  if invoice_row.subtotal > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, revenue_id, invoice_row.subtotal, invoice_row.currency_code);
  end if;
  if invoice_row.tax_amount > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, vat_payable_id, invoice_row.tax_amount, invoice_row.currency_code);
  end if;
  if invoice_row.other_charges > 0 then
    insert into public.books_journal_lines (transaction_id, account_id, credit, currency_code)
    values (journal_id, other_charges_account_id, invoice_row.other_charges, invoice_row.currency_code);
  end if;
end;
$$;
revoke all on function public.post_sales_invoice_recognition(uuid) from public, anon, authenticated;

create or replace function public.post_hotel_invoice_recognition(target_invoice_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  perform public.post_sales_invoice_recognition(target_invoice_id);
end;
$$;
revoke all on function public.post_hotel_invoice_recognition(uuid) from public, anon, authenticated;

create or replace function public.post_menu_event_invoice_recognition()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from 'paid') then
    perform public.post_sales_invoice_recognition(new.id);
  end if;
  return new;
end;
$$;
revoke all on function public.post_menu_event_invoice_recognition() from public, anon, authenticated;

drop trigger if exists books_menu_event_invoice_recognition on public.books_invoices;
create trigger books_menu_event_invoice_recognition
after insert or update of status on public.books_invoices
for each row when (new.invoice_number like 'MENU-%' or new.invoice_number like 'EVENT-%')
execute function public.post_menu_event_invoice_recognition();
