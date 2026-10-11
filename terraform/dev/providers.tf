terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # No remote backend on purpose. The long-lived production infrastructure
  # (this repo's other, not-yet-built terraform root module) needs shared,
  # locked state because it's always-on; this one is created and destroyed
  # within a single test session, so there's nothing to share across
  # machines or protect with a lock. State lives as a local file in this
  # directory only — never commit it (see the root .gitignore).
}

provider "aws" {
  region = var.aws_region

  # No default_tags — tags are set per-resource in main.tf's
  # local.common_tags instead (a leftover from when an IAM role/instance
  # profile existed here and needed excluding from it; both are gone now,
  # but per-resource tagging is just as simple to keep as to unwind).
}
