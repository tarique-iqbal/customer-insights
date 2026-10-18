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

  # No remote backend yet, same as terraform/dev for now — but unlike dev,
  # this tier isn't meant to be destroyed after every test session (see
  # notes/aws-qna.md's "isn't as disposable" note), so local state here is
  # a bigger risk than it is for dev: there's more to lose, and nothing
  # stops two people (or two machines) applying at once. Add an S3 (+
  # DynamoDB, or S3 native locking on TF >=1.10) backend before this is
  # used by more than one person/machine, or left running long enough that
  # losing the state file would actually hurt.
}

provider "aws" {
  region = var.aws_region
}
