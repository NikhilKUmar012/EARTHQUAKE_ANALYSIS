USE earthquake;

-- Q1 | Beginner | How many earthquakes struck in the last 24 hours, split by magnitude class?
SELECT class_name,
       COUNT(*)                 AS quakes,
       ROUND(AVG(magnitude), 2) AS avg_mag,
       MAX(magnitude)           AS max_mag
FROM v_quake_enriched
WHERE event_time >= DATE_SUB((SELECT now_ts FROM v_clock), INTERVAL 24 HOUR)
GROUP BY class_id, class_name
ORDER BY class_id;


-- Q2 | Beginner | Which are the 10 strongest earthquakes of the last 7 days?
SELECT quake_id, event_time, magnitude, region, place, depth_km, tsunami_flag
FROM fact_quake
WHERE event_time >= DATE_SUB((SELECT now_ts FROM v_clock), INTERVAL 7 DAY)
ORDER BY magnitude DESC, event_time DESC
LIMIT 10;


-- Q3 | Beginner | Leaderboard: which regions are the most seismically active, and how strong are they?
SELECT region,
       COUNT(*)                             AS quakes,
       ROUND(AVG(magnitude), 2)             AS avg_mag,
       MAX(magnitude)                       AS max_mag,
       ROUND(AVG(depth_km), 1)              AS avg_depth_km,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS activity_rank
FROM fact_quake
GROUP BY region
ORDER BY quakes DESC
LIMIT 10;


-- Q4 | Beginner | Are deep earthquakes stronger than shallow ones? Profile quakes by depth class.
SELECT depth_class,
       COUNT(*)                                           AS quakes,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_all,
       ROUND(AVG(magnitude), 2)                           AS avg_mag,
       MAX(magnitude)                                     AS max_mag,
       SUM(tsunami_flag)                                  AS tsunami_flags
FROM v_quake_enriched
GROUP BY depth_class
ORDER BY MIN(depth_km);


-- Q5 | Time-series | How many earthquakes per hour over the last 48 hours (and the strongest each hour)?
SELECT DATE_FORMAT(event_time, '%Y-%m-%d %H:00') AS hour_utc,
       COUNT(*)                                  AS quakes,
       MAX(magnitude)                            AS max_mag
FROM fact_quake
WHERE event_time >= DATE_SUB((SELECT now_ts FROM v_clock), INTERVAL 48 HOUR)
GROUP BY hour_utc
ORDER BY hour_utc;


-- Q6 | Time-series | Smooth the noise: what are the 6-hour and 24-hour moving averages of hourly quake counts?
WITH hourly AS (
    SELECT DATE_FORMAT(event_time, '%Y-%m-%d %H:00') AS hour_utc,
           COUNT(*)                                  AS quakes
    FROM fact_quake
    WHERE event_time >= DATE_SUB((SELECT now_ts FROM v_clock), INTERVAL 7 DAY)
    GROUP BY hour_utc
)
SELECT hour_utc, quakes,
       ROUND(AVG(quakes) OVER (ORDER BY hour_utc ROWS BETWEEN  5 PRECEDING AND CURRENT ROW), 2) AS ma_6h,
       ROUND(AVG(quakes) OVER (ORDER BY hour_utc ROWS BETWEEN 23 PRECEDING AND CURRENT ROW), 2) AS ma_24h
FROM hourly
ORDER BY hour_utc DESC
LIMIT 24;


-- Q7 | Time-series | Day by day, did global activity go up or down versus the previous day?
WITH daily AS (
    SELECT DATE(event_time) AS event_day,
           COUNT(*)         AS quakes,
           MAX(magnitude)   AS max_mag
    FROM fact_quake
    GROUP BY DATE(event_time)
)
SELECT event_day, quakes,
       LAG(quakes) OVER (ORDER BY event_day) AS prev_day,
       ROUND(100.0 * (quakes - LAG(quakes) OVER (ORDER BY event_day))
                   / NULLIF(LAG(quakes) OVER (ORDER BY event_day), 0), 1) AS day_over_day_pct,
       max_mag
FROM daily
ORDER BY event_day DESC
LIMIT 14;


-- Q8 | Time-series | At what hour of the day (UTC) do most quakes get recorded? (text bar chart made in pure SQL)
-- One '#' per 40 quakes, rounded up so every hour with data shows at least one '#'.
SELECT DATE_FORMAT(event_time, '%H')                AS hour_utc,
       COUNT(*)                                     AS quakes,
       REPEAT('#', CEILING(COUNT(*) / 40))          AS bar
FROM fact_quake
GROUP BY hour_utc
ORDER BY hour_utc;


-- Q9 | Time-series | What were the longest "quiet spells" between two consecutive M5+ earthquakes?
WITH big AS (
    SELECT event_time, magnitude, region,
           LAG(event_time) OVER (ORDER BY event_time) AS prev_time
    FROM fact_quake
    WHERE magnitude >= 5.0
)
SELECT prev_time                                                   AS quiet_from,
       event_time                                                  AS quiet_until,
       ROUND(TIMESTAMPDIFF(SECOND, prev_time, event_time) / 3600, 1) AS gap_hours,
       magnitude                                                   AS ended_by_mag,
       region
FROM big
WHERE prev_time IS NOT NULL
ORDER BY gap_hours DESC
LIMIT 5;


-- Q10 | Geospatial | Which big cities have had M5+ earthquakes within 500 km (Haversine distance)?
SELECT city_name, country,
       COUNT(*)       AS m5_plus_quakes,
       MAX(magnitude) AS strongest,
       MIN(dist_km)   AS closest_km
FROM v_quake_city_dist
WHERE magnitude >= 5.0 AND dist_km <= 500
GROUP BY city_id, city_name, country
ORDER BY m5_plus_quakes DESC, strongest DESC;


-- Q11 | Geospatial | For every M6+ earthquake, which is the nearest major city and how far away?
WITH ranked AS (
    SELECT quake_id, event_time, magnitude, region, city_name, dist_km,
           ROW_NUMBER() OVER (PARTITION BY quake_id ORDER BY dist_km) AS rn
    FROM v_quake_city_dist
    WHERE magnitude >= 6.0
)
SELECT event_time, magnitude, region, city_name AS nearest_city, dist_km
FROM ranked
WHERE rn = 1
ORDER BY magnitude DESC, event_time DESC;


-- Q12 | Geospatial | Which cities are most exposed? (population-weighted shaking proxy of M3+ quakes within 300 km)
--            NOTE: teaching heuristic, NOT a real hazard model.
SELECT city_name, country, population_m,
       COUNT(*)       AS quakes_within_300km,
       MAX(magnitude) AS strongest,
       ROUND(population_m * SUM(POWER(10, 0.5 * magnitude) / (1 + dist_km)), 1) AS exposure_score
FROM v_quake_city_dist
WHERE magnitude >= 3.0 AND dist_km <= 300
GROUP BY city_id, city_name, country, population_m
ORDER BY exposure_score DESC
LIMIT 10;


-- Q13 | Advanced | How much energy did each region release, in "Hiroshima bomb" equivalents?
SELECT region,
       COUNT(*)                                                              AS quakes,
       MAX(magnitude)                                                        AS max_mag,
       ROUND(SUM(energy_joules) / 1e15, 2)                                   AS energy_petajoules,
       ROUND(SUM(hiroshima_equiv), 0)                                        AS hiroshima_bombs,
       ROUND(100.0 * SUM(energy_joules) / SUM(SUM(energy_joules)) OVER (), 2) AS pct_of_global_energy
FROM v_quake_enriched
GROUP BY region
ORDER BY energy_petajoules DESC
LIMIT 10;


-- Q14 | Engineering | Pivot table: how many quakes of each magnitude class per region? (conditional aggregation)
SELECT region,
       COUNT(*)                                                   AS total,
       SUM(CASE WHEN class_name = 'Micro'    THEN 1 ELSE 0 END)   AS micro,
       SUM(CASE WHEN class_name = 'Minor'    THEN 1 ELSE 0 END)   AS minor,
       SUM(CASE WHEN class_name = 'Light'    THEN 1 ELSE 0 END)   AS light,
       SUM(CASE WHEN class_name = 'Moderate' THEN 1 ELSE 0 END)   AS moderate,
       SUM(CASE WHEN class_name = 'Strong'   THEN 1 ELSE 0 END)   AS strong,
       SUM(CASE WHEN class_name = 'Major'    THEN 1 ELSE 0 END)   AS major,
       SUM(CASE WHEN class_name = 'Great'    THEN 1 ELSE 0 END)   AS great
FROM v_quake_enriched
GROUP BY region
ORDER BY total DESC
LIMIT 12;


-- Q15 | Engineering | Which cities sit within 500 km of a tsunami-flagged earthquake, and how many people live there?
SELECT city_name, country, population_m,
       COUNT(*)       AS tsunami_flagged_quakes,
       MAX(magnitude) AS strongest,
       MIN(dist_km)   AS closest_km
FROM v_quake_city_dist
WHERE tsunami_flag = 1 AND dist_km <= 500
GROUP BY city_id, city_name, country, population_m
ORDER BY tsunami_flagged_quakes DESC, population_m DESC;


-- Q16 | Engineering | What did the alert rules raise automatically? Show the latest 20 alerts (the live alert feed).
SELECT alert_id, created_at, severity, alert_type, region, magnitude, nearest_city, distance_km, message
FROM alert_log
ORDER BY created_at DESC, alert_id DESC
LIMIT 20;