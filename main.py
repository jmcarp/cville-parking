import calendar
import datetime
import logging
import re
from typing import Dict, List

import requests
import lxml.html
from google.cloud import bigquery
from google.cloud import monitoring_v3

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


LOTS = ["market", "water"]
BASE_URL = "https://widget.charlottesville.org/parkingcounter/parkinglot"
IMG_PATTERN = re.compile(r"images/([b\d])[a-z]\.gif", re.IGNORECASE)


def get_spaces(lot: str) -> int:
    resp = requests.get(BASE_URL, params={"lotname": lot})
    resp.raise_for_status()
    doc = lxml.html.fromstring(resp.content)
    digits = [
        image_to_digit(image)
        for image in doc.xpath("//div[@id='divAvailableSpaces']/img/@src")
    ]
    while digits and digits[0] == "b":
        digits = digits[1:]
    assert len(digits) > 0
    return int("".join(digits))


def image_to_digit(url: str) -> str:
    match = IMG_PATTERN.search(url)
    assert match is not None
    return match.groups()[0]


def record_metrics(client, project_id: str, rows: List[Dict], timestamp: float):
    project_path = client.common_project_path(project_id)
    series = [
        record_metric_series(row["lot"], row["spaces"], timestamp) for row in rows
    ]
    client.create_time_series(request={"name": project_path, "time_series": series})


def record_metric_series(
    lot: str, spaces: int, timestamp: float
) -> monitoring_v3.types.TimeSeries:
    series = monitoring_v3.types.TimeSeries()
    series.metric.type = "custom.googleapis.com/spaces"
    series.resource.type = "global"
    series.metric.labels["lot"] = lot
    seconds = int(timestamp)
    nanos = int((timestamp - seconds) * 10 ** 9)
    interval = monitoring_v3.TimeInterval(
        {"end_time": {"seconds": seconds, "nanos": nanos}}
    )
    point = monitoring_v3.Point(
        {"interval": interval, "value": {"int64_value": spaces}}
    )
    series.points = [point]
    return series


def update_spaces(event, context) -> None:
    bigquery_client = bigquery.Client()
    metrics_client = monitoring_v3.MetricServiceClient()
    timestamp = datetime.datetime.utcnow()

    project_id = event["attributes"]["project_id"]
    dataset_id = event["attributes"]["dataset_id"]
    table_id = event["attributes"]["table_id"]

    rows = []
    for lot in LOTS:
        spaces = get_spaces(lot)
        logger.info(f"{spaces} spaces available in lot {lot}")
        rows.append({"lot": lot, "timestamp": timestamp, "spaces": spaces})

    table = bigquery_client.get_table(f"{project_id}.{dataset_id}.{table_id}")
    errors = bigquery_client.insert_rows(table, rows)

    record_metrics(
        metrics_client, project_id, rows, calendar.timegm(timestamp.timetuple())
    )

    if len(errors) > 0:
        raise RuntimeError(errors)
