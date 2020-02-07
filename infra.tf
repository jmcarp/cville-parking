terraform {
  backend "gcs" {
  }
}

provider "google" {
  region  = "us-central1"
  project = var.project
}

provider "google-beta" {
  region  = "us-central1"
  project = var.project
}

variable "project" {
  default = "cville-parking"
}

variable "lot_capacities" {
  type = map(number)
  default = {
    market = 480
    water  = 900
  }
}

variable "email_address" {
  default = "jm.carp@gmail.com"
}

resource "google_bigquery_dataset" "parking" {
  dataset_id = "parking"

  // Default access
  access {
    role          = "OWNER"
    user_by_email = var.email_address
  }
  access {
    role          = "OWNER"
    special_group = "projectOwners"
  }
  access {
    role          = "READER"
    special_group = "projectReaders"
  }
  access {
    role          = "WRITER"
    special_group = "projectWriters"
  }

  // Public read-only access
  access {
    role          = "READER"
    special_group = "allAuthenticatedUsers"
  }
}

resource "google_bigquery_table" "public" {
  dataset_id = google_bigquery_dataset.parking.dataset_id
  table_id   = "public"
  schema     = <<EOF
[
  {
    "name": "lot",
    "type": "STRING",
    "mode": "NULLABLE"
  },
  {
    "name": "timestamp",
    "type": "TIMESTAMP",
    "mode": "NULLABLE"
  },
  {
    "name": "spaces",
    "type": "INTEGER",
    "mode": "NULLABLE"
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

resource "google_monitoring_alert_policy" "scrape" {
  provider              = google-beta
  display_name          = "scrape"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "executions"

    condition_threshold {
      comparison      = "COMPARISON_LT"
      duration        = "600s"
      filter          = "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" resource.type=\"cloud_function\" resource.label.\"function_name\"=\"scrape\" metric.label.\"status\"=\"ok\""
      threshold_value = 1

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_COUNT"
      }

      trigger {
        count = 1
      }
    }
  }
}

resource "google_monitoring_alert_policy" "scrape_high" {
  for_each = var.lot_capacities
  provider = google-beta

  display_name          = "scrape-${each.key}-high"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.name]

  conditions {
    display_name = "spaces over capacity for ${each.key}"

    condition_threshold {
      comparison      = "COMPARISON_GT"
      duration        = "300s"
      filter          = "metric.type=\"custom.googleapis.com/spaces\" resource.type=\"global\" metric.label.\"lot\"=\"${each.key}\""
      threshold_value = each.value

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }

      trigger {
        count = 1
      }
    }
  }
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "email"
  type         = "email"
  labels = {
    email_address = var.email_address
  }
}
