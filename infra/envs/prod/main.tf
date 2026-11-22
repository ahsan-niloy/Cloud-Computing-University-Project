module "network" {
  source = "../../modules/network"

  vpc_cidr = var.vpc_cidr
  subnets  = var.subnets
}

module "database" {
  source = "../../modules/database"

  vpc_id              = module.network.vpc_id
  isolated_subnet_ids = module.network.isolated_subnet_ids
}

module "app" {
  source = "../../modules/app"

  vpc_id             = module.network.vpc_id
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  db_sg_id           = module.database.db_sg_id
  db_endpoint        = module.database.db_endpoint
}
