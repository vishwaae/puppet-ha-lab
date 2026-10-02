region      = "us-east-1"
aws_profile = "terraform2426"

name        = "htc-b"
environment = "dev"
managed_by  = "Terraform-Please do not add/modify manually"
owner       = "Vish-Philip"

ami_id                     = "ami-0aedf6b1cb669b4c7"
instance_type              = "c7i-flex.large"
key_name                   = "terraform2426"
root_volume_size           = 25
root_volume_type           = "gp3"
enable_detailed_monitoring = true

workers = {
  worker1 = { private_ip = "10.1.0.70", hostgroup = "infra" }
  worker2 = { private_ip = "10.1.0.80", hostgroup = "webserver" }
  worker3 = { private_ip = "10.1.0.90", hostgroup = "admin" }
}

trusted_cidrs = [
  "106.219.179.232/32",
]
