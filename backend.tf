terraform {
  backend "s3" {
    bucket         = "terraform-state-buckettt"
    key            = "terraform/state.tfstate"
    region         = "ap-south-2"
    encrypt        = true
  }
}
