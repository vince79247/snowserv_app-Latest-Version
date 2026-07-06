-- Geofenced pricing zones: each service_areas row can carry a `polygon`
-- boundary (jsonb: an ordered list of {lat,lng} vertices). A customer's
-- geocoded address is tested against these polygons (point-in-polygon, in the
-- app) to pick the zone whose prices apply. The legacy `zips` column remains a
-- fallback for zones that have no polygon drawn yet.
alter table service_areas add column if not exists polygon jsonb;
