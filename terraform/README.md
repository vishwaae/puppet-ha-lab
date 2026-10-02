When you start this lab from AWS, first run worker_setup and change the following values in terraform.tfvars files before running it. Otherwise, you will get an error.

From peering_connection_id = "pcx-0f3f79e809ede9b4a" to peering_connection_id = ""

From account_a_bucket_name = "htc-backups-333679559305" to account_a_bucket_name = ""

trusted_cidrs = [
  "106.219.179.232/32", - This should be your laptop/desktop IP address. Run #curl -4 -L ipconfig.me --> you will get your IP address and replace 106.219.179.232/32
]

#cd worker_setup 
#terraform init
#terraform plan --out=tfplan
#terraform apply tfplan

Now go to the puppetmaster folder. Change the following values before running it. Otherwise, you will get an error.

From rancherb_vpc_id = "vpc-0e97a82313c589e81" to the VPC ID that you created in the first step (worker_setup).

From account_b_account_id = "223681698720" to account_b_account_id = "your AWS second account ID"

#cd puppetmaster
#terraform init
#terraform plan --out=tfplan
#terraform apply tfplan

Again, go back to the worker_setup folder. Change the following values:

From peering_connection_id = "pcx-0f3f79e809ede9b4a" to the peering connection ID output from puppetmaster.

From account_a_bucket_name = "htc-backups-333679559305" to the account_a_bucket_name output from puppetmaster.

Then run:

#terraform init
#terraform plan --out=tfplan
#terraform apply tfplan

Once the peering connection is active, log in to each node and ping all the nodes.

Dont run the worker_setup_agent folder.Once all the puppetmaster and ca node,admin node setup completed successfully then touch worker_setup_agent.
