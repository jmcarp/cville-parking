terraform {
  backend "gcs" {
  }
}

provider "google" {
  region  = "us-central1"
  project = var.project
}

variable "project" {
  default = "cville-parking"
}

resource "google_bigquery_dataset" "parking" {
  dataset_id = "parking"
}

resource "google_bigquery_table" "public" {
  dataset_id = google_bigquery_dataset.parking.dataset_id
  table_id   = "public"
  schema     = <<EOF
[
  {
    "name": "lot",
    "type": "STRING"
  },
  {
    "name": "timestamp",
    "type": "TIMESTAMP"
  },
  {
    "name": "spaces",
    "type": "INT64"
  }
]
EOF
}

data "archive_file" "scrape" {
  type        = "zip"
  output_path = "${path.module}/scrape.zip"

  source {
    content  = file("${path.module}/requirements.txt")
    filename = "requirements.txt"
  }

  source {
    content  = file("${path.module}/main.py")
    filename = "main.py"
  }
}

resource "google_storage_bucket" "functions" {
  project = var.project
  name    = "cville-parking-functions"
}

resource "google_storage_bucket_object" "scrape" {
  name   = "${data.archive_file.scrape.output_sha}.zip"
  bucket = google_storage_bucket.functions.name
  source = data.archive_file.scrape.output_path
}

resource "google_pubsub_topic" "scrape" {
  project = var.project
  name    = "scrape"
}

resource "google_cloudfunctions_function" "scrape" {
  project = var.project
  name    = "scrape"
  runtime = "python37"

  source_archive_bucket = google_storage_bucket.functions.name
  source_archive_object = google_storage_bucket_object.scrape.name
  entry_point           = "update_spaces"

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.scrape.name
  }

  depends_on = [google_storage_bucket_object.scrape]
}

resource "google_cloud_scheduler_job" "scrape" {
  project  = var.project
  name     = "scrape"
  schedule = "*/5 * * * *"

  pubsub_target {
    topic_name = google_pubsub_topic.scrape.id
    attributes = {
      project_id = var.project
      dataset_id = google_bigquery_dataset.parking.dataset_id
      table_id   = google_bigquery_table.public.table_id
    }
  }
}
