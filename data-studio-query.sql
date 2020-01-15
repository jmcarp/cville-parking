-- Custom data source for data studio
WITH hourly AS (
  SELECT
    spaces,
    TIMESTAMP_TRUNC(timestamp, HOUR) AS timestamp,
  FROM `cville-parking.parking.public`
  WHERE lot = @lot
)
SELECT
  timestamp,
  AVG(spaces) AS spaces,
	EXTRACT(HOUR FROM DATETIME(timestamp, 'US/Eastern')) AS hour,
	FORMAT_DATETIME('%A', DATETIME(timestamp, 'US/Eastern')) AS day,
  EXTRACT(DAYOFWEEK FROM DATETIME(timestamp, 'US/Eastern')) AS day_of_week
FROM hourly
GROUP BY timestamp
