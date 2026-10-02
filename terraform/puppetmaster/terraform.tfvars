name                        = "htc"
environment                 = "dev"
managed_by                  = "Terraform-Please do not add/modify manually"
owner                       = "Vish-Philip"
#ami_id                     = "ami-0f8a61b66d1accaee"
ami_id                      = "ami-0aedf6b1cb669b4c7"
root_volume_size            = "25"
root_volume_type            = "gp3"
root_volume_encrypted       = true
availability_zone           = "us-east-1a"
enable_detailed_monitoring  = true
associate_public_ip_address = true

master_instance_type_ha  = "m7i-flex.large"
master_instance_type_std = "c7i-flex.large"
worker_instance_type     = "c7i-flex.large"

trusted_cidrs = [
  "106.219.179.232/32",
]

account_b_account_id = "223681698720"   # from aws sts get-caller-identity --profile vidh
# Empty until rancherB (puppetca2/worker1-3) is applied — peering and the
# S3 cross-account policy are both skipped automatically while this is "".
# Once rancherB exists, set this to its real vpc_id output and re-apply.
rancherb_vpc_id      = "vpc-0e97a82313c589e81"
longhorn_disk_size = 40

static_private_ips = {
  puppetmaster1 = "10.0.1.10"
  puppetmaster2 = "10.0.1.20"
  puppetmaster3 = "10.0.1.30"
  puppetca1     = "10.0.1.40"
}