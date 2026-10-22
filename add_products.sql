-- Run in Supabase > SQL Editor (after schema.sql).

insert into categories(name) values ('Instant and premix') on conflict (name) do nothing;

-- New products, all with stock 0 (shown as "Out of stock" until you add inventory in Admin > Products).
-- Photos are built into index.html (matched by product name); upload your own in Admin to override.
insert into products(category_id, name, description, price, stock_quantity, image_url) values
 ((select category_id from categories where name='Single estate'),  'Mysore Nuggets Extra Bold', 'Large, dense arabica beans ground bold for strong filter kaapi. 250 g.', 395, 0, null),
 ((select category_id from categories where name='Single estate'),  'Monsooned Malabar AA', 'Beans aged in monsoon winds for a mellow, low-acid cup. 250 g.', 450, 0, null),
 ((select category_id from categories where name='Filter coffee'),  'Dark Roast French Style', 'Deep roast with a smoky finish, ground medium for the filter. 250 g.', 310, 0, null),
 ((select category_id from categories where name='Single estate'),  'Decaf Arabica', 'Water-processed decaffeinated arabica. 250 g.', 480, 0, null),
 ((select category_id from categories where name='Instant and premix'), 'Jaggery Kaapi Premix', 'Coffee, milk powder and jaggery. Add hot water. 200 g.', 299, 0, null),
 ((select category_id from categories where name='Gift packs'),     'Sampler Trio', 'Three 100 g packs: filter blend, robusta and peaberry.', 799, 0, null);

-- Optional: let Admin upload real photos from the product form.
insert into storage.buckets(id, name, public) values ('product-images', 'product-images', true)
on conflict (id) do nothing;
create policy "public read product images" on storage.objects for select
  using (bucket_id = 'product-images');
create policy "admin uploads product images" on storage.objects for insert
  with check (bucket_id = 'product-images' and public.is_admin());
