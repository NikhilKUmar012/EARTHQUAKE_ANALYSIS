CREATE DATABASE IF NOT EXISTS earthquake;
USE earthquake;

INSERT INTO stg_quake_raw
    (event_id, mag, place, time_ms, updated_ms, felt, cdi, mmi, alert,
     status, tsunami, sig, net, mag_type, event_type, lon, lat, depth_km,
     ingested_at, processed)
VALUES
    ('us7000abcd', 6.1, '12 km NNE of Hitachi, Japan', 1714000000000, 1714003600000,
     420, 5.2, 5.8, 'yellow', 'reviewed', 0, 612, 'us', 'mww', 'earthquake',
     140.65, 36.71, 35.2, UTC_TIMESTAMP(), 0),
    ('us7000abce', 4.3, '8 km SW of Anchorage, Alaska', 1714001200000, 1714001200000,
     85, 4.0, 4.5, NULL, 'automatic', 0, 285, 'ak', 'ml', 'earthquake',
     -149.95, 61.18, 42.0, UTC_TIMESTAMP(), 0),
    ('us7000abcf', 7.2, '95 km SSE of Perryville, Alaska', 1714002400000, 1714006000000,
     1500, 6.5, 7.0, 'orange', 'reviewed', 1, 850, 'us', 'mww', 'earthquake',
     -158.20, 55.10, 28.5, UTC_TIMESTAMP(), 0)
ON DUPLICATE KEY UPDATE
    mag        = VALUES(mag),
    place      = VALUES(place),
    time_ms    = VALUES(time_ms),
    updated_ms = VALUES(updated_ms),
    felt       = VALUES(felt),
    cdi        = VALUES(cdi),
    mmi        = VALUES(mmi),
    alert      = VALUES(alert),
    status     = VALUES(status),
    tsunami    = VALUES(tsunami),
    sig        = VALUES(sig),
    net        = VALUES(net),
    mag_type   = VALUES(mag_type),
    event_type = VALUES(event_type),
    lon        = VALUES(lon),
    lat        = VALUES(lat),
    depth_km   = VALUES(depth_km),
    ingested_at = VALUES(ingested_at),
    processed  = 0;

INSERT INTO ingest_log (polled_at, feed, fetched, new_or_upd, status)
VALUES (UTC_TIMESTAMP(),
        'https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson',
        3, ROW_COUNT(), 'OK');

-- ============================================================
-- STEP 2: BRONZE -> SILVER (fact_quake)
-- ============================================================
INSERT INTO fact_quake
    (quake_id, event_time, updated_time, magnitude, mag_type, place, region,
     latitude, longitude, depth_km, significance, tsunami_flag, felt_reports,
     pager_alert, review_status, network, ingested_at)
SELECT
    event_id,
    FROM_UNIXTIME(time_ms  / 1000),
    FROM_UNIXTIME(updated_ms / 1000),
    mag,
    mag_type,
    place,
    COALESCE(NULLIF(TRIM(SUBSTRING_INDEX(place, ',', -1)), ''), 'Unknown'),
    lat,
    lon,
    depth_km,
    COALESCE(sig, 0),
    CASE WHEN tsunami = 1 THEN 1 ELSE 0 END,
    COALESCE(felt, 0),
    CASE WHEN alert IN ('green','yellow','orange','red') THEN alert ELSE NULL END,
    status,
    net,
    ingested_at
FROM stg_quake_raw
WHERE processed = 0
  AND mag IS NOT NULL
  AND lat BETWEEN -90  AND 90
  AND lon BETWEEN -180 AND 180
  AND time_ms IS NOT NULL
ON DUPLICATE KEY UPDATE
    updated_time  = VALUES(updated_time),
    magnitude     = VALUES(magnitude),
    place         = VALUES(place),
    region        = VALUES(region),
    significance  = VALUES(significance),
    tsunami_flag  = VALUES(tsunami_flag),
    felt_reports  = VALUES(felt_reports),
    pager_alert   = VALUES(pager_alert),
    review_status = VALUES(review_status);

UPDATE stg_quake_raw
SET processed = 1
WHERE processed = 0
  AND mag IS NOT NULL
  AND lat BETWEEN -90 AND 90
  AND lon BETWEEN -180 AND 180;

-- ============================================================
-- STEP 3: POPULATE dim_magnitude_class
-- ============================================================
INSERT IGNORE INTO dim_magnitude_class (class_id, class_name, min_mag, max_mag) VALUES
 (1, 'Micro',     -1.0,  2.0),
 (2, 'Minor',      2.0,  4.0),
 (3, 'Light',      4.0,  5.0),
 (4, 'Moderate',   5.0,  6.0),
 (5, 'Strong',     6.0,  7.0),
 (6, 'Major',      7.0,  8.0),
 (7, 'Great',      8.0, 10.0);

-- ============================================================
-- STEP 4: BUILD ALERTS (alert_log)
-- ============================================================

-- Rule A: MAJOR_QUAKE — mag >= 6.0 with nearest city within 500 km
INSERT INTO alert_log
    (quake_id, alert_type, severity, region, magnitude, nearest_city,
     distance_km, message, created_at)
SELECT
    fq.quake_id, 'MAJOR_QUAKE',
    CASE
        WHEN fq.magnitude >= 8.0 THEN 'RED'
        WHEN fq.magnitude >= 7.0 THEN 'ORANGE'
        ELSE 'YELLOW'
    END,
    fq.region, fq.magnitude, nc.city_name, nc.dist,
    CONCAT('M', fq.magnitude, ' near ', fq.place, ' (',
           ROUND(nc.dist,0), ' km from ', nc.city_name, ')'),
    UTC_TIMESTAMP()
FROM fact_quake fq
JOIN (
    SELECT fq2.quake_id, dc.city_name,
           ROUND(6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(dc.latitude  - fq2.latitude )/2),2) +
                COS(RADIANS(fq2.latitude))*COS(RADIANS(dc.latitude)) *
                POWER(SIN(RADIANS(dc.longitude - fq2.longitude)/2),2)
           )), 1) AS dist
    FROM fact_quake fq2
    JOIN dim_city dc
      ON ABS(dc.latitude  - fq2.latitude ) < 6
     AND ABS(dc.longitude - fq2.longitude) < 6
    WHERE fq2.magnitude >= 6.0
) nc ON nc.quake_id = fq.quake_id
WHERE fq.magnitude >= 6.0
  AND nc.dist <= 500
  AND NOT EXISTS (
      SELECT 1 FROM alert_log a
      WHERE a.quake_id = fq.quake_id AND a.alert_type = 'MAJOR_QUAKE'
  );

-- Rule B: TSUNAMI_FLAG — tsunami_flag = 1
INSERT INTO alert_log
    (quake_id, alert_type, severity, region, magnitude, nearest_city,
     distance_km, message, created_at)
SELECT
    fq.quake_id, 'TSUNAMI_FLAG', 'ORANGE', fq.region, fq.magnitude,
    NULL, NULL,
    CONCAT('Tsunami message issued for M', fq.magnitude, ' — ', fq.place),
    UTC_TIMESTAMP()
FROM fact_quake fq
WHERE fq.tsunami_flag = 1
  AND NOT EXISTS (
      SELECT 1 FROM alert_log a
      WHERE a.quake_id = fq.quake_id AND a.alert_type = 'TSUNAMI_FLAG'
  );

-- Rule C: ACTIVITY_SPIKE — 3+ quakes M>=5.0 in same region within 24h
INSERT INTO alert_log
    (quake_id, alert_type, severity, region, magnitude, nearest_city,
     distance_km, message, created_at)
SELECT
    fq.quake_id, 'ACTIVITY_SPIKE', 'YELLOW', fq.region, fq.magnitude,
    NULL, NULL,
    CONCAT('Activity spike: ', cnt.n, ' quakes M>=5 in ', fq.region,
           ' within 24h'),
    UTC_TIMESTAMP()
FROM fact_quake fq
JOIN (
    SELECT region, COUNT(*) AS n
    FROM fact_quake
    WHERE magnitude >= 5.0
      AND event_time >= UTC_TIMESTAMP() - INTERVAL 24 HOUR
    GROUP BY region
    HAVING COUNT(*) >= 3
) cnt ON cnt.region = fq.region
WHERE fq.magnitude >= 5.0
  AND fq.event_time >= UTC_TIMESTAMP() - INTERVAL 24 HOUR
  AND NOT EXISTS (
      SELECT 1 FROM alert_log a
      WHERE a.quake_id = fq.quake_id
        AND a.alert_type = 'ACTIVITY_SPIKE'
        AND a.created_at >= UTC_TIMESTAMP() - INTERVAL 24 HOUR
  );

-- Rule D: MAGNITUDE_UPGRADE — magnitude rose > 0.3 over last alerted value
INSERT INTO alert_log
    (quake_id, alert_type, severity, region, magnitude, nearest_city,
     distance_km, message, created_at)
SELECT
    fq.quake_id, 'MAGNITUDE_UPGRADE', 'YELLOW', fq.region, fq.magnitude,
    NULL, NULL,
    CONCAT('Magnitude upgraded to M', fq.magnitude, ' — ', fq.place),
    UTC_TIMESTAMP()
FROM fact_quake fq
JOIN (
    SELECT quake_id, MAX(magnitude) AS prev_mag
    FROM alert_log
    WHERE alert_type = 'MAJOR_QUAKE'
    GROUP BY quake_id
) prev ON prev.quake_id = fq.quake_id
WHERE fq.magnitude > prev.prev_mag + 0.3
  AND NOT EXISTS (
      SELECT 1 FROM alert_log a
      WHERE a.quake_id = fq.quake_id
        AND a.alert_type = 'MAGNITUDE_UPGRADE'
        AND a.magnitude = fq.magnitude
  );

-- ============================================================
-- STEP 5: VERIFICATION QUERIES
-- ============================================================
SELECT 'stg_quake_raw' AS tbl, COUNT(*) AS rows_,
       SUM(processed=0) AS pending, SUM(processed=1) AS done
FROM stg_quake_raw
UNION ALL SELECT 'fact_quake', COUNT(*), NULL, NULL FROM fact_quake
UNION ALL SELECT 'dim_city', COUNT(*), NULL, NULL FROM dim_city
UNION ALL SELECT 'dim_magnitude_class', COUNT(*), NULL, NULL FROM dim_magnitude_class
UNION ALL SELECT 'alert_log', COUNT(*), NULL, NULL FROM alert_log
UNION ALL SELECT 'ingest_log', COUNT(*), NULL, NULL FROM ingest_log;

SELECT COUNT(*) AS bad_rows
FROM fact_quake
WHERE region IS NULL OR region = ''
   OR latitude  NOT BETWEEN  -90 AND  90
   OR longitude NOT BETWEEN -180 AND 180
   OR magnitude IS NULL;

SELECT a.created_at, a.alert_type, a.severity, a.region,
       a.magnitude, a.nearest_city, a.distance_km, a.message
FROM alert_log a
ORDER BY a.created_at DESC
LIMIT 20;