# Fetch cluster details using your exact cluster name
data "aws_eks_cluster" "eks" {
  name = "tooling-app-eks"
}

# 1. Create the IAM Role for the CSI Driver
resource "aws_iam_role" "ebs_csi_driver_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  # This trust policy allows the EKS cluster to assume this role via OIDC
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.eks.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

# 2. Attach the official AWS managed policy for EBS CSI to the role
resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver_role.name
}

# 3. Finally, install the EKS Add-on using the role we just created
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = "tooling-app-eks"
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver_role.arn
  
  # Ensure the role and policy exist before trying to create the addon
  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver_policy_attachment
  ]
}
