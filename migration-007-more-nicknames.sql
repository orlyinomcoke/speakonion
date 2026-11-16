-- Speak Onion – migration 007: bigger nickname word lists
-- Run once in Supabase SQL Editor. Existing nicknames stay the same; new users get the bigger variety.
-- 131 adjectives x 130 words x 999 numbers = about 17,012,970 unique nicknames.

create or replace function public.gen_nickname() returns text
language plpgsql volatile set search_path = public as $$
declare
  adj text[] := array['Agile','Amber','Bold','Brave','Breezy','Bright','Calm','Cheeky','Chill','Chirpy','Clever','Cosmic','Cozy','Crafty','Crispy','Curious','Dapper','Daring','Dreamy','Dusky','Eager','Earnest','Electric','Epic','Fancy','Fearless','Feisty','Fierce','Fiery','Fluffy','Frosty','Fuzzy','Gallant','Gentle','Giddy','Glossy','Golden','Groovy','Happy','Hasty','Hazy','Hearty','Honest','Humble','Hyper','Icy','Jazzy','Jolly','Jumpy','Keen','Kind','Lively','Lofty','Loud','Loyal','Lucid','Lucky','Magic','Mellow','Merry','Mighty','Misty','Modest','Mystic','Neon','Nifty','Nimble','Noble','Nomad','Peppy','Perky','Plucky','Plush','Polite','Proud','Quiet','Quirky','Radiant','Rapid','Rowdy','Royal','Rustic','Rusty','Salty','Serene','Shiny','Silent','Silly','Sleepy','Sly','Smart','Smooth','Snappy','Snowy','Soft','Sparky','Speedy','Spicy','Spry','Spunky','Steady','Stellar','Stormy','Sturdy','Sunlit','Sunny','Super','Swanky','Sweet','Swift','Tangy','Thrifty','Tidy','Tiny','Tough','Turbo','Upbeat','Velvet','Vibrant','Vivid','Warm','Wild','Wiry','Wise','Witty','Wobbly','Woolly','Zany','Zen','Zesty','Zippy'];
  noun text[] := array['Acacia','Adobo','Agila','Alamid','Alon','Anahaw','Apo','Araw','Atis','Baguio','Bagyo','Bakunawa','Bamboo','Banca','Bangka','Bangus','Banig','Barquillos','Bayawak','Bayong','Bibingka','Biko','Bituin','Bohol','Boracay','Bulalo','Bulkan','Bundok','Butanding','Buwan','Carabao','Champorado','Chicharon','Chico','Coconut','Dagat','Dalisay','Datu','Dugong','Duhat','Durian','Ensaymada','Fishball','Gumamela','Guyabano','Halohalo','Hangin','Haribon','Ilangilang','Ilog','Inasal','Isaw','Jeepney','Kakanin','Kalabaw','Kalamansi','Kalaw','Kamia','Kamias','Kangkong','Kidlat','Kinilaw','Kutsinta','Kwekkwek','Laing','Lakan','Langka','Lanzones','Lechon','Liwayway','Longganisa','Lugaw','Lumpia','Maja','Mango','Mangosteen','Maya','Mayon','Molave','Monsoon','Narra','Onion','Otap','Palawan','Palitaw','Pancit','Pandesal','Papaya','Parol','Pastillas','Pawikan','Payong','Piaya','Pili','Pinakbet','Polvoron','Pulag','Rambutan','Rosal','Sagada','Saging','Salakot','Sampaguita','Santol','Sapin','Sarimanok','Siargao','Sinigang','Siniguelas','Siopao','Suman','Taal','Taho','Tahong','Tala','Talaba','Talisay','Tamaraw','Tapsilog','Tarsier','Tikling','Tinola','Tocino','Tsinelas','Turon','Ube','Ulan','Ulap','Vigan','Yema'];
  candidate text;
  tries int := 0;
begin
  loop
    candidate := adj[1 + floor(random() * array_length(adj, 1))::int]
              || noun[1 + floor(random() * array_length(noun, 1))::int]
              || (1 + floor(random() * 999))::int::text;
    exit when not exists (select 1 from public.profiles where nickname = candidate);
    tries := tries + 1;
    if tries > 50 then candidate := candidate || floor(random() * 10)::int::text; exit; end if;
  end loop;
  return candidate;
end $$;
