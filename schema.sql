-- Malabar Kaapi e-commerce backend (Supabase / PostgreSQL)
-- Run the whole file once in Supabase > SQL Editor.

-- ---------- Tables (3NF) ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text, phone text,
  role text not null default 'customer' check (role in ('customer','admin')),
  created_at timestamptz default now()
);
create table addresses (
  address_id bigserial primary key,
  customer_id uuid not null references profiles(id) on delete cascade,
  line1 text not null, city text not null, state text not null, pincode text not null
);
create table categories (
  category_id bigserial primary key,
  name text not null unique
);
create table products (
  product_id bigserial primary key,
  category_id bigint not null references categories(category_id),
  name text not null, description text,
  price numeric(10,2) not null check (price >= 0),
  stock_quantity int not null default 0 check (stock_quantity >= 0),
  image_url text,
  is_active boolean not null default true
);
create table carts (
  cart_id bigserial primary key,
  customer_id uuid not null unique references profiles(id) on delete cascade
);
create table cart_items (
  cart_id bigint references carts(cart_id) on delete cascade,
  product_id bigint references products(product_id) on delete cascade,
  quantity int not null check (quantity > 0),
  primary key (cart_id, product_id)
);
create table orders (
  order_id bigserial primary key,
  customer_id uuid not null references profiles(id),
  address_id bigint not null references addresses(address_id),
  total numeric(10,2) not null default 0,
  status text not null default 'Placed' check (status in ('Placed','Shipped','Delivered','Cancelled')),
  created_at timestamptz default now()
);
create table order_items (
  order_id bigint references orders(order_id) on delete cascade,
  product_id bigint references products(product_id),
  quantity int not null check (quantity > 0),
  unit_price numeric(10,2) not null,
  primary key (order_id, product_id)
);
create table payments (
  payment_id bigserial primary key,
  order_id bigint not null unique references orders(order_id) on delete cascade,
  amount numeric(10,2) not null,
  method text not null check (method in ('COD','UPI','Card')),
  status text not null default 'Pending' check (status in ('Pending','Paid','Refunded'))
);
create table reviews (
  review_id bigserial primary key,
  customer_id uuid not null references profiles(id) on delete cascade,
  product_id bigint not null references products(product_id) on delete cascade,
  reviewer_name text,
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz default now(),
  unique (customer_id, product_id)
);
create index on products(category_id);
create index on orders(customer_id);
create index on orders(status);

-- ---------- Helpers ----------
create function is_admin() returns boolean language sql stable security definer
set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin')
$$;

-- On sign-up: create profile + cart
create function handle_new_user() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  insert into profiles(id, full_name, phone)
  values (new.id, new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'phone');
  insert into carts(customer_id) values (new.id);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
for each row execute function handle_new_user();

-- ---------- Trigger 1: reduce stock on order_items insert (atomic, rejects if short) ----------
create function trg_reduce_stock() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  update products set stock_quantity = stock_quantity - new.quantity
  where product_id = new.product_id and stock_quantity >= new.quantity;
  if not found then
    raise exception 'Not enough stock for product %', new.product_id;
  end if;
  return new;
end $$;
create trigger reduce_stock after insert on order_items
for each row execute function trg_reduce_stock();

-- ---------- Trigger 2: restore stock when an order becomes Cancelled ----------
create function trg_restore_stock() returns trigger language plpgsql security definer
set search_path = public as $$
begin
  if new.status = 'Cancelled' and old.status <> 'Cancelled' then
    update products p set stock_quantity = p.stock_quantity + oi.quantity
    from order_items oi where oi.order_id = new.order_id and oi.product_id = p.product_id;
    update payments set status = 'Refunded' where order_id = new.order_id and status = 'Paid';
  end if;
  return new;
end $$;
create trigger restore_stock after update of status on orders
for each row execute function trg_restore_stock();

-- ---------- Stored procedure: order total = sum(quantity x price) ----------
create function order_total(p_order bigint) returns numeric language sql stable as $$
  select coalesce(sum(quantity * unit_price), 0) from order_items where order_id = p_order
$$;

-- ---------- Checkout: one atomic transaction ----------
create function place_order(p_address_id bigint, p_method text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); cid bigint; oid bigint; amt numeric; confirmed timestamptz;
begin
  if uid is null then raise exception 'Please log in'; end if;
  select email_confirmed_at into confirmed from auth.users where id = uid;
  if confirmed is null then raise exception 'Verify your email before ordering'; end if;
  if not exists (select 1 from addresses where address_id = p_address_id and customer_id = uid) then
    raise exception 'Choose a delivery address';
  end if;
  select cart_id into cid from carts where customer_id = uid;
  if not exists (select 1 from cart_items where cart_id = cid) then
    raise exception 'Your cart is empty';
  end if;
  insert into orders(customer_id, address_id) values (uid, p_address_id) returning order_id into oid;
  insert into order_items(order_id, product_id, quantity, unit_price)
    select oid, ci.product_id, ci.quantity, p.price
    from cart_items ci join products p on p.product_id = ci.product_id where ci.cart_id = cid;
  amt := order_total(oid);
  update orders set total = amt where order_id = oid;
  insert into payments(order_id, amount, method, status)
    values (oid, amt, p_method, case when p_method = 'COD' then 'Pending' else 'Paid' end);
  delete from cart_items where cart_id = cid;
  return oid;
end $$;

create function cancel_order(p_order bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update orders set status = 'Cancelled'
  where order_id = p_order and customer_id = auth.uid() and status = 'Placed';
  if not found then raise exception 'Only orders that are still Placed can be cancelled'; end if;
end $$;

-- ---------- Row level security (role-based access) ----------
alter table profiles enable row level security;
alter table addresses enable row level security;
alter table categories enable row level security;
alter table products enable row level security;
alter table carts enable row level security;
alter table cart_items enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;
alter table payments enable row level security;
alter table reviews enable row level security;

create policy "own profile" on profiles for select using (id = auth.uid() or is_admin());
create policy "edit own profile" on profiles for update using (id = auth.uid())
  with check (id = auth.uid() and (role = 'customer' or is_admin()));

create policy "own addresses" on addresses for all using (customer_id = auth.uid())
  with check (customer_id = auth.uid());
create policy "admin reads addresses" on addresses for select using (is_admin());

create policy "public categories" on categories for select using (true);
create policy "admin categories" on categories for all using (is_admin()) with check (is_admin());
create policy "public products" on products for select using (is_active or is_admin());
create policy "admin products" on products for all using (is_admin()) with check (is_admin());

create policy "own cart" on carts for select using (customer_id = auth.uid());
create policy "own cart items" on cart_items for all
  using (cart_id in (select cart_id from carts where customer_id = auth.uid()))
  with check (cart_id in (select cart_id from carts where customer_id = auth.uid()));

create policy "own orders" on orders for select using (customer_id = auth.uid() or is_admin());
create policy "admin updates orders" on orders for update using (is_admin()) with check (is_admin());
create policy "own order items" on order_items for select
  using (order_id in (select order_id from orders where customer_id = auth.uid()) or is_admin());
create policy "own payments" on payments for select
  using (order_id in (select order_id from orders where customer_id = auth.uid()) or is_admin());
create policy "admin updates payments" on payments for update using (is_admin()) with check (is_admin());

create policy "public reviews" on reviews for select using (true);
create policy "write own review" on reviews for insert with check (customer_id = auth.uid());
create policy "edit own review" on reviews for update using (customer_id = auth.uid());
create policy "delete own review" on reviews for delete using (customer_id = auth.uid() or is_admin());

-- ---------- Sample data ----------
insert into categories(name) values ('Filter coffee'), ('Single estate'), ('Gift packs');
insert into products(category_id, name, description, price, stock_quantity) values
 (1,'Classic Filter Blend 80:20','Roasted arabica with 20% chicory, ground for the South Indian filter. 250 g.',285,40),
 (1,'Strong Decoction Blend 70:30','Darker roast, more chicory, for milk-heavy kaapi. 250 g.',260,35),
 (2,'Wayanad Robusta AAA','Bold, low-acid robusta from Wayanad estates. 250 g.',340,25),
 (2,'Chikmagalur-style Peaberry','Round, sweet peaberry beans, medium roast. 250 g.',420,18),
 (2,'Cold Brew Coarse Grind','Coarse grind made for 12-hour cold brew. 250 g.',380,22),
 (3,'Kaapi Gift Box','Two blends, a steel tumbler and davara set. 500 g.',1250,10);

-- After you register on the site, make yourself admin (replace the email):
-- update profiles set role = 'admin' where id = (select id from auth.users where email = 'you@example.com');
