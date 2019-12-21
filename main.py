import datetime
import logging
import re

import requests
import lxml.html
from google.cloud import bigquery

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


PROJECT_ID = "cville-parking"
DATASET_ID = "parking"
TABLE_NAME = "public"
LOTS = ["market", "water"]
BASE_URL = "https://widget.charlottesville.org/parkingcounter/parkinglot"
IMG_PATTERN = re.compile(r"images/([b\d])[a-z]\.gif", re.IGNORECASE)


def get_spaces(lot: str) -> int:
    url = f"{BASE_URL}?lotname={lot}"
    resp = requests.get(url)
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


def image_to_digit(url) -> str:
    match = IMG_PATTERN.search(url)
    assert match is not None
    return match.groups()[0]


def update_spaces(event, context) -> None:
    client = bigquery.Client()
    timestamp = datetime.datetime.utcnow()

    rows = []
    for lot in LOTS:
        spaces = get_spaces(lot)
        logger.info(f"{spaces} spaces available in lot {lot}")
        rows.append({"lot": lot, "timestamp": timestamp, "spaces": spaces})

    table = client.get_table(f"{PROJECT_ID}.{DATASET_ID}.{TABLE_NAME}")
    errors = client.insert_rows(table, rows)
    if len(errors) > 0:
        raise RuntimeError(errors)


if __name__ == "__main__":
    update_spaces(None, None)
