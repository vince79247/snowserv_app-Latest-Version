-- Saved addresses become a LIST, so they need names.
--
-- The app assumed one home per customer: loadAddress() took a single row and
-- the address screen edited it in place, so a second property could only be
-- reached through "ordering for someone else" — retyped in full, every storm,
-- and saved as a throwaway row. Three kids in three houses meant typing three
-- addresses every time it snowed.
--
-- A label is what makes a list usable: "Mom's" and "the rental" are how people
-- actually think about their properties, and a picker showing four near-
-- identical street lines is no better than retyping. Optional — an unlabelled
-- address just shows its street.
alter table public.addresses
  add column if not exists label text;

comment on column public.addresses.label is
  'Customer''s own name for this property ("Home", "Mom''s"). Optional; the '
  'picker falls back to the street line. Not shown to providers — they get the '
  'street address, and a label is a private mnemonic, not part of the address.';
