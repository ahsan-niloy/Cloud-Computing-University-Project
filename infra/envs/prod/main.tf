module "network" {
  source = "../../modules/network"

  vpc_cidr = var.vpc_cidr
  subnets  = var.subnets
}
