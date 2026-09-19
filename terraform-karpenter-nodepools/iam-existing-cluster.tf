# Only used when create_cluster = false. When create_cluster = true, the node
# role is created and managed by the Karpenter submodule in karpenter-bootstrap.tf
# instead, since it also needs to set up IRSA/access entries against the new cluster.

data "aws_partition" "current" {}

resource "aws_iam_role" "karpenter_node" {
  count = var.create_cluster ? 0 : 1
  name  = var.node_iam_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.${data.aws_partition.current.dns_suffix}" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  count      = var.create_cluster ? 0 : 1
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  count      = var.create_cluster ? 0 : 1
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_readonly" {
  count      = var.create_cluster ? 0 : 1
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.create_cluster ? 0 : 1
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  count = var.create_cluster ? 0 : 1
  name  = "${var.node_iam_role_name}-profile"
  role  = aws_iam_role.karpenter_node[0].name
  tags  = var.tags
}
