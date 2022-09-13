variable "vcp_cidr" {
  default = "10.0.0.0/16"
}

variable "region" {
  default = "eu-north-1"
}

variable "public_subnet" {
  default = [
      "10.0.1.0/24",
      "10.0.2.0/24"]
}

variable "private_subnet" {
  default = [
    "10.0.11.0/24",
    "10.0.22.0/24"]
}


