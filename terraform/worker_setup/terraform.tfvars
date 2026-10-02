name                        = "htc-b"
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

# Leave empty for the FIRST apply. Fill in after rancherA is applied,
# then re-apply — purely additive (peering accepter + route).
# Empty until rancherA's peering is re-established (deferred there too,
# see rancherA's rancherb_vpc_id = ""). Both sides' peering resources are
# count-gated on this being set, so leaving it blank correctly skips
# them here rather than referencing a dead connection ID.
peering_connection_id = "pcx-0f3f79e809ede9b4a"

account_a_bucket_name = "htc-backups-333679559305"

longhorn_disk_size = "40"

static_private_ips = {
  puppetca2 = "10.1.0.50"
  admin     = "10.1.0.60"
}